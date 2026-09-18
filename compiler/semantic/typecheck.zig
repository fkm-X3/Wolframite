const std = @import("std");
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");
const types_mod = @import("types.zig");
const scope_mod = @import("scope.zig");

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const Node = ast.Node;
const NodeIdx = ast.NodeIdx;
const NodeList = ast.NodeList;
const StringRef = ast.StringRef;
const BinaryOp = ast.BinaryOp;
const TypePool = types_mod.TypePool;
const TypeIdx = types_mod.TypeIdx;
const SemType = types_mod.SemType;
const FloatKind = types_mod.FloatKind;

pub const TypeChecker = struct {
    allocator: Allocator,
    arena: *AstArena,
    source: []const u8,
    type_pool: *TypePool,
    diagnostics: *diag.Diagnostics,
    module_node: NodeIdx,

    node_types: std.ArrayListUnmanaged(TypeIdx),
    scopes: scope_mod.ScopeStack,

    fn_ret_type: TypeIdx,
    in_function: bool,

    type_name_buf: [2][16]u8,
    type_name_toggle: u1 = 0,

    void_ty: TypeIdx,
    bool_ty: TypeIdx,
    i8_ty: TypeIdx,
    i16_ty: TypeIdx,
    i32_ty: TypeIdx,
    i64_ty: TypeIdx,
    u8_ty: TypeIdx,
    u16_ty: TypeIdx,
    u32_ty: TypeIdx,
    u64_ty: TypeIdx,
    f32_ty: TypeIdx,
    f64_ty: TypeIdx,
    string_ty: TypeIdx,

    pub fn init(
        allocator: Allocator,
        arena: *AstArena,
        source: []const u8,
        type_pool: *TypePool,
        diagnostics: *diag.Diagnostics,
        resolver_scopes: *const scope_mod.ScopeStack,
        module_node: NodeIdx,
    ) TypeChecker {
        const void_ty = type_pool.add(.void) catch @panic("OOM");
        const bool_ty = type_pool.add(.bool_type) catch @panic("OOM");
        const i8_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 8 } }) catch @panic("OOM");
        const i16_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 16 } }) catch @panic("OOM");
        const i32_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 32 } }) catch @panic("OOM");
        const i64_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 64 } }) catch @panic("OOM");
        const u8_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 8 } }) catch @panic("OOM");
        const u16_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 16 } }) catch @panic("OOM");
        const u32_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 32 } }) catch @panic("OOM");
        const u64_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 64 } }) catch @panic("OOM");
        const f32_ty = type_pool.add(.{ .float = .f32 }) catch @panic("OOM");
        const f64_ty = type_pool.add(.{ .float = .f64 }) catch @panic("OOM");
        const string_ty = type_pool.add(.string_type) catch @panic("OOM");

        var node_types: std.ArrayListUnmanaged(TypeIdx) = .empty;
        node_types.append(allocator, void_ty) catch @panic("OOM");

        var scopes = scope_mod.ScopeStack.init(allocator);
        const module_scope = scopes.pushScope(null) catch @panic("OOM");
        if (resolver_scopes.scopeCount() > 0) {
            var it = resolver_scopes.scopes.items[0].symbols.iterator();
            while (it.next()) |entry| {
                scopes.insert(entry.key_ptr.*, entry.value_ptr.*) catch @panic("OOM");
            }
        }
        _ = module_scope;

        return .{
            .allocator = allocator,
            .arena = arena,
            .source = source,
            .type_pool = type_pool,
            .diagnostics = diagnostics,
            .scopes = scopes,
            .module_node = module_node,
            .node_types = node_types,
            .fn_ret_type = void_ty,
            .in_function = false,
            .type_name_buf = undefined,
            .type_name_toggle = 0,
            .void_ty = void_ty,
            .bool_ty = bool_ty,
            .i8_ty = i8_ty,
            .i16_ty = i16_ty,
            .i32_ty = i32_ty,
            .i64_ty = i64_ty,
            .u8_ty = u8_ty,
            .u16_ty = u16_ty,
            .u32_ty = u32_ty,
            .u64_ty = u64_ty,
            .f32_ty = f32_ty,
            .f64_ty = f64_ty,
            .string_ty = string_ty,
        };
    }

    fn builtinTypeName(self: *const TypeChecker, name: []const u8) ?TypeIdx {
        if (std.mem.eql(u8, name, "void")) return self.void_ty;
        if (std.mem.eql(u8, name, "bool")) return self.bool_ty;
        if (std.mem.eql(u8, name, "i8")) return self.i8_ty;
        if (std.mem.eql(u8, name, "i16")) return self.i16_ty;
        if (std.mem.eql(u8, name, "i32")) return self.i32_ty;
        if (std.mem.eql(u8, name, "i64")) return self.i64_ty;
        if (std.mem.eql(u8, name, "u8")) return self.u8_ty;
        if (std.mem.eql(u8, name, "u16")) return self.u16_ty;
        if (std.mem.eql(u8, name, "u32")) return self.u32_ty;
        if (std.mem.eql(u8, name, "u64")) return self.u64_ty;
        if (std.mem.eql(u8, name, "f32")) return self.f32_ty;
        if (std.mem.eql(u8, name, "f64")) return self.f64_ty;
        if (std.mem.eql(u8, name, "String")) return self.string_ty;
        return null;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.node_types.deinit(self.allocator);
        self.scopes.deinit();
    }

    pub fn check(self: *TypeChecker) !void {
        const mod = self.arena.get(self.module_node);
        for (mod.module.decls.indices) |decl_idx| {
            try self.checkDecl(decl_idx);
        }
    }

    fn nameSlice(self: *const TypeChecker, ref: StringRef) []const u8 {
        return ref.slice(self.source);
    }

    fn errorAt(self: *TypeChecker, _: NodeIdx, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch |err| {
            std.debug.panic("OOM in typechecker: {s}", .{@errorName(err)});
        };
        self.diagnostics.add(.@"error", .semantic, msg, null) catch {};
    }

    fn setNodeType(self: *TypeChecker, node: NodeIdx, ty: TypeIdx) void {
        const idx = node.toInt();
        while (self.node_types.items.len <= idx) {
            self.node_types.append(self.allocator, self.void_ty) catch @panic("OOM");
        }
        self.node_types.items[idx] = ty;
    }

    fn getNodeType(self: *const TypeChecker, node: NodeIdx) TypeIdx {
        const idx = node.toInt();
        if (idx < self.node_types.items.len) {
            return self.node_types.items[idx];
        }
        return self.void_ty;
    }
    pub fn nodeType(self: *const TypeChecker, node: NodeIdx) TypeIdx {
        return self.getNodeType(node);
    }

    fn checkDecl(self: *TypeChecker, decl_idx: NodeIdx) anyerror!void {
        const decl = self.arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => try self.checkFnDecl(decl_idx),
            .struct_decl => try self.checkStructDecl(decl_idx),
            .enum_decl => try self.checkEnumDecl(decl_idx),
            .interface_decl => try self.checkInterfaceDecl(decl_idx),
            .impl_block => |ib| {
                _ = ib;
                for (decl.impl_block.methods.indices) |method_idx| {
                    try self.checkDecl(method_idx);
                }
            },
            else => {},
        }
    }

    fn checkStructDecl(self: *TypeChecker, decl_idx: NodeIdx) anyerror!void {
        const decl = self.arena.get(decl_idx);
        const s = decl.struct_decl;
        for (s.methods.indices) |method_idx| {
            try self.checkDecl(method_idx);
        }
    }

    fn checkEnumDecl(self: *TypeChecker, decl_idx: NodeIdx) !void {
        const decl = self.arena.get(decl_idx);
        const e = decl.enum_decl;
        // Type the variant payload types so match arms can bind them.
        // Generic enums (Option[T]) leave payloads unresolved until
        // monomorphization lands.
        if (e.generic_params.indices.len == 0) {
            for (e.variants.indices) |variant_idx| {
                const variant = self.arena.get(variant_idx);
                for (variant.enum_variant.fields.indices) |field_idx| {
                    _ = self.inferExprType(field_idx);
                }
            }
        }
    }

    fn checkInterfaceDecl(_: *TypeChecker, _: NodeIdx) !void {}

    fn checkFnDecl(self: *TypeChecker, fn_idx: NodeIdx) anyerror!void {
        const fn_decl = self.arena.get(fn_idx);
        const f = fn_decl.fn_decl;

        const prev_ret = self.fn_ret_type;
        const prev_in_fn = self.in_function;

        self.in_function = true;
        if (f.return_type) |ret_ty| {
            self.fn_ret_type = self.inferTypeRef(ret_ty);
        } else {
            self.fn_ret_type = self.void_ty;
        }

        self.setNodeType(fn_idx, self.fn_ret_type);

        const fn_scope = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");

        for (f.generic_params.indices) |gp_idx| {
            const gp = self.arena.get(gp_idx);
            self.scopes.insert(self.nameSlice(gp.identifier), .{
                .name = gp.identifier,
                .kind = .generic_param,
                .decl_node = gp_idx,
                .type_idx = TypeIdx.none,
            }) catch @panic("OOM");
        }

        for (f.params.indices) |param_idx| {
            const param = self.arena.get(param_idx);
            self.scopes.insert(self.nameSlice(param.param.name), .{
                .name = param.param.name,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = self.inferTypeRef(param.param.ty),
            }) catch @panic("OOM");
        }

        if (f.body != NodeIdx.none) {
            try self.checkStmt(f.body);
        }

        self.scopes.popScope();
        _ = fn_scope;

        self.fn_ret_type = prev_ret;
        self.in_function = prev_in_fn;
    }

    fn checkStmt(self: *TypeChecker, stmt_idx: NodeIdx) anyerror!void {
        const stmt = self.arena.get(stmt_idx);
        switch (stmt.*) {
            .block => |b| {
                _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
                for (b.stmts.indices) |inner| {
                    try self.checkStmt(inner);
                }
                self.scopes.popScope();
            },
            .let_stmt => |l| {
                var declared_ty: TypeIdx = self.void_ty;
                if (l.ty) |ty| {
                    declared_ty = self.inferTypeRef(ty);
                }
                self.setNodeType(stmt_idx, declared_ty);

                if (l.init_expr) |init_val| {
                    const init_ty = self.inferExprType(init_val);
                    if (l.ty) |_| {
                        if (!self.typesEqual(declared_ty, init_ty)) {
                            self.errorAt(stmt_idx, "type mismatch: expected '{s}' but got '{s}'", .{
                                self.typeName(declared_ty), self.typeName(init_ty),
                            });
                        }
                    }
                    self.setNodeType(stmt_idx, init_ty);
                }

                self.scopes.insert(self.nameSlice(l.name), .{
                    .name = l.name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = self.getNodeType(stmt_idx),
                }) catch @panic("OOM");
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    const val_ty = self.inferExprType(val);
                    if (!self.typesEqual(val_ty, self.fn_ret_type)) {
                        self.errorAt(stmt_idx, "return type mismatch: expected '{s}' but got '{s}'", .{
                            self.typeName(self.fn_ret_type), self.typeName(val_ty),
                        });
                    }
                }
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .expr_stmt => |e| {
                _ = self.inferExprType(e.expr);
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .defer_stmt => |d| {
                _ = self.inferExprType(d.expr);
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .if_expr => |i| {
                const cond_ty = self.inferExprType(i.cond);
                if (!self.typesEqual(cond_ty, self.bool_ty)) {
                    self.errorAt(stmt_idx, "if condition must be bool, got '{s}'", .{self.typeName(cond_ty)});
                }
                try self.checkStmt(i.then_body);
                if (i.else_body) |else_b| {
                    try self.checkStmt(else_b);
                }
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .while_expr => |w| {
                const cond_ty = self.inferExprType(w.cond);
                if (!self.typesEqual(cond_ty, self.bool_ty)) {
                    self.errorAt(stmt_idx, "while condition must be bool, got '{s}'", .{self.typeName(cond_ty)});
                }
                try self.checkStmt(w.body);
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .for_range => |fr| {
                _ = self.inferExprType(fr.start);
                _ = self.inferExprType(fr.end);
                _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
                self.scopes.insert(self.nameSlice(fr.var_name), .{
                    .name = fr.var_name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = self.i32_ty,
                }) catch @panic("OOM");
                try self.checkStmt(fr.body);
                self.scopes.popScope();
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .for_each => |fe| {
                const iter_ty = self.inferExprType(fe.iterable);
                const var_ty = self.forEachElemType(stmt_idx, iter_ty);
                _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
                self.scopes.insert(self.nameSlice(fe.var_name), .{
                    .name = fe.var_name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = var_ty,
                }) catch @panic("OOM");
                try self.checkStmt(fe.body);
                self.scopes.popScope();
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .match_expr => |m| {
                try self.checkMatchStmt(stmt_idx, m);
            },
            .fn_decl => {
                try self.checkFnDecl(stmt_idx);
            },
            else => {
                _ = self.inferExprType(stmt_idx);
            },
        }
    }

    fn inferExprType(self: *TypeChecker, expr_idx: NodeIdx) TypeIdx {
        const prev = self.getNodeType(expr_idx);
        if (prev != self.void_ty) return prev;

        const expr = self.arena.get(expr_idx);
        const ty = self.inferExprTypeInner(expr_idx, expr);
        self.setNodeType(expr_idx, ty);
        return ty;
    }

    fn inferExprTypeInner(self: *TypeChecker, expr_idx: NodeIdx, expr: *const Node) TypeIdx {
        switch (expr.*) {
            .int_literal => return self.i32_ty,
            .float_literal => return self.f64_ty,
            .string_literal => return self.string_ty,
            .char_literal => return self.i32_ty,
            .bool_literal => return self.bool_ty,
            .null_literal => return self.void_ty,
            .identifier => |id| {
                const name = self.nameSlice(id);
                if (self.builtinTypeName(name)) |ty| return ty;
                if (ast.findEnumVariant(self.arena, self.source, self.module_node, name)) |vi| {
                    return self.resolveDeclType(vi.enum_decl);
                }
                if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                    if (sym.type_idx != TypeIdx.none) {
                        return sym.type_idx;
                    }
                    return self.resolveDeclType(sym.decl_node);
                }
                return self.void_ty;
            },
            .binary_op => |b| {
                const left_ty = self.inferExprType(b.left);
                const right_ty = self.inferExprType(b.right);

                if (b.op == .assign or b.op == .add_assign or b.op == .sub_assign or
                    b.op == .mul_assign or b.op == .div_assign)
                {
                    if (!self.typesEqual(left_ty, right_ty)) {
                        self.errorAt(expr_idx, "assignment type mismatch: '{s}' and '{s}'", .{
                            self.typeName(left_ty), self.typeName(right_ty),
                        });
                    }
                    return left_ty;
                }

                if (b.op == .eq or b.op == .ne or b.op == .lt or b.op == .gt or
                    b.op == .le or b.op == .ge)
                {
                    if (!self.typesEqual(left_ty, right_ty)) {
                        self.errorAt(expr_idx, "comparison of incompatible types: '{s}' and '{s}'", .{
                            self.typeName(left_ty), self.typeName(right_ty),
                        });
                    }
                    return self.bool_ty;
                }

                if (b.op == .and_op or b.op == .or_op) {
                    if (!self.typesEqual(left_ty, self.bool_ty)) {
                        self.errorAt(expr_idx, "logical op requires bool operands", .{});
                    }
                    return self.bool_ty;
                }

                if (!self.typesEqual(left_ty, right_ty)) {
                    self.errorAt(expr_idx, "binary op type mismatch: '{s}' and '{s}'", .{
                        self.typeName(left_ty), self.typeName(right_ty),
                    });
                }

                if (b.op == .range) return self.i32_ty;
                return left_ty;
            },
            .unary_op => |u| {
                return self.inferExprType(u.operand);
            },
            .call => |c| {
                return self.inferCallType(expr_idx, c);
            },
            .field_access => |fa| {
                const obj_ty = self.inferExprType(fa.object);
                const obj_sem_type = self.type_pool.get(obj_ty);
                switch (obj_sem_type) {
                    .struct_type => |decl_node| {
                        if (self.structFieldType(decl_node, self.nameSlice(fa.field))) |ft| {
                            return ft;
                        }
                        const s = self.arena.get(decl_node).struct_decl;
                        self.errorAt(expr_idx, "struct '{s}' has no field '{s}'", .{
                            self.nameSlice(s.name), self.nameSlice(fa.field),
                        });
                        return self.void_ty;
                    },
                    .pointer => |elem| {
                        const elem_type = self.type_pool.get(elem);
                        switch (elem_type) {
                            .struct_type => |decl_node| {
                                if (self.structFieldType(decl_node, self.nameSlice(fa.field))) |ft| {
                                    return ft;
                                }
                                self.errorAt(expr_idx, "struct has no field '{s}'", .{self.nameSlice(fa.field)});
                                return self.void_ty;
                            },
                            else => {},
                        }
                        self.errorAt(expr_idx, "cannot access field on non-struct type", .{});
                        return self.void_ty;
                    },
                    else => {
                        self.errorAt(expr_idx, "cannot access field on type '{s}'", .{self.typeName(obj_ty)});
                        return self.void_ty;
                    },
                }
            },
            .index_access => |ia| {
                const obj_ty = self.inferExprType(ia.object);
                _ = self.inferExprType(ia.index);
                return self.inferElementType(expr_idx, obj_ty);
            },
            .paren_expr => |p| {
                return self.inferExprType(p);
            },
            .impl_type => |inner| {
                const inner_ty = self.inferExprType(inner);
                const sem = self.type_pool.get(inner_ty);
                if (sem != .interface_type) {
                    self.errorAt(expr_idx, "'impl' requires an interface type, got a non-interface type", .{});
                    return self.void_ty;
                }
                return inner_ty;
            },
            .struct_init => |si| {
                return self.inferExprType(si.ty);
            },
            .range_expr => |r| {
                _ = self.inferExprType(r.start);
                _ = self.inferExprType(r.end);
                return self.i32_ty;
            },
            .closure => |cl| {
                for (cl.params.indices) |param_idx| {
                    const param = self.arena.get(param_idx);
                    if (param.param.ty != NodeIdx.none) {
                        _ = self.inferExprType(param.param.ty);
                    }
                }
                _ = self.inferExprType(cl.body);
                return self.void_ty;
            },
            .comptime_block => |inner| {
                tryStd(self.checkStmt(inner));
                return self.void_ty;
            },
            .comptime_expr => |inner| return self.inferExprType(inner),
            .comptime_call => |cc| {
                for (cc.args.indices) |arg| {
                    _ = self.inferExprType(arg);
                }
                return self.i32_ty;
            },
            .pipeline => |p| {
                _ = self.inferExprType(p.lhs);
                return self.inferExprType(p.rhs);
            },
            .try_propagate => |inner| return self.inferExprType(inner),
            .move_expr => |inner| return self.inferExprType(inner),
            .region_expr => |r| {
                if (r.allocator) |alloc_ty| {
                    _ = self.inferExprType(alloc_ty);
                }
                tryStd(self.checkStmt(r.body));
                return self.void_ty;
            },
            .block => |b| {
                tryStd(self.checkStmt(expr_idx));
                if (b.stmts.indices.len > 0) {
                    const last = self.arena.get(b.stmts.indices[b.stmts.indices.len - 1]);
                    if (last.* == .expr_stmt) {
                        return self.inferExprType(last.expr_stmt.expr);
                    }
                    return self.getNodeType(b.stmts.indices[b.stmts.indices.len - 1]);
                }
                return self.void_ty;
            },
            .if_expr => |i| {
                const cond_ty = self.inferExprType(i.cond);
                if (!self.typesEqual(cond_ty, self.bool_ty)) {
                    self.errorAt(expr_idx, "if condition must be bool", .{});
                }
                const then_ty = self.inferExprType(i.then_body);
                var else_ty: TypeIdx = self.void_ty;
                if (i.else_body) |else_b| {
                    else_ty = self.inferExprType(else_b);
                }
                if (!self.typesEqual(then_ty, else_ty)) {
                    if (i.else_body != null) {
                        self.errorAt(expr_idx, "if branches have different types", .{});
                    }
                }
                return then_ty;
            },
            .match_expr => |m| {
                const scrut_ty = self.inferExprType(m.scrutinee);
                var result_ty: TypeIdx = self.void_ty;
                if (self.type_pool.get(scrut_ty) == .enum_type) {
                    const enum_node = self.type_pool.get(scrut_ty).enum_type;
                    for (m.arms.indices) |arm_idx| {
                        result_ty = tryStdTy(self.checkEnumArm(arm_idx, enum_node));
                    }
                } else {
                    for (m.arms.indices) |arm_idx| {
                        const arm = self.arena.get(arm_idx);
                        _ = self.inferExprType(arm.match_arm.pattern);
                        if (arm.match_arm.guard) |guard| {
                            _ = self.inferExprType(guard);
                        }
                        result_ty = self.inferExprType(arm.match_arm.body);
                    }
                }
                return result_ty;
            },
            else => return self.void_ty,
        }
    }

    fn inferTypeRef(self: *TypeChecker, expr_idx: NodeIdx) TypeIdx {
        return self.inferExprType(expr_idx);
    }

    // ========================================================================
    // Calls
    // ========================================================================

    /// Type of a call expression. Handles plain function calls, enum variant
    /// constructors (`Some(x)`), and method calls on structs/classes and
    /// `*impl Interface` fat pointers.
    fn inferCallType(self: *TypeChecker, expr_idx: NodeIdx, c: anytype) TypeIdx {
        for (c.args.indices) |arg| {
            _ = self.inferExprType(arg);
        }

        const callee = self.arena.get(c.func);
        switch (callee.*) {
            .identifier => |id| {
                const name = self.nameSlice(id);
                if (ast.findEnumVariant(self.arena, self.source, self.module_node, name)) |vi| {
                    self.checkEnumVariantCall(expr_idx, vi, c);
                    return self.type_pool.add(.{ .enum_type = vi.enum_decl }) catch self.void_ty;
                }
                if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                    if (sym.kind == .function) {
                        const f = self.arena.get(sym.decl_node).fn_decl;
                        self.checkCallArgs(expr_idx, f.params, c.args);
                        if (f.return_type) |ret| return self.inferExprType(ret);
                        return self.void_ty;
                    }
                }
                return self.i32_ty;
            },
            .field_access => |fa| {
                const obj_ty = self.inferExprType(fa.object);
                return self.inferMethodReturn(expr_idx, obj_ty, self.nameSlice(fa.field)) orelse self.void_ty;
            },
            else => return self.i32_ty,
        }
    }

    /// Lightweight arg/param agreement: arg count plus interface satisfaction
    /// for `*impl Interface` parameters. Deep type matching is left to the
    /// lowerer's slot-based conventions.
    fn checkCallArgs(self: *TypeChecker, node_idx: NodeIdx, params: NodeList, args: NodeList) void {
        if (params.indices.len != args.indices.len) {
            self.errorAt(node_idx, "call has {d} arguments but the function takes {d}", .{
                args.indices.len, params.indices.len,
            });
        }
        const count = @min(params.indices.len, args.indices.len);
        for (0..count) |i| {
            const param = self.arena.get(params.indices[i]);
            const arg_ty = self.inferExprType(args.indices[i]);
            const param_ty = self.inferTypeRef(param.param.ty);
            if (self.paramWantsInterface(param_ty)) |iface_node| {
                if (!self.satisfiesInterface(arg_ty, iface_node)) {
                    self.errorAt(node_idx, "type '{s}' does not satisfy interface '{s}'", .{
                        self.typeName(arg_ty), self.typeName(self.type_pool.add(.{ .interface_type = iface_node }) catch self.void_ty),
                    });
                }
            }
        }
    }

    /// If `ty` is a `*impl I` parameter type, return the interface decl node.
    fn paramWantsInterface(self: *const TypeChecker, ty: TypeIdx) ?NodeIdx {
        var sem = self.type_pool.get(ty);
        if (sem == .pointer) sem = self.type_pool.get(sem.pointer);
        if (sem == .interface_type) return sem.interface_type;
        return null;
    }

    /// Structural satisfaction: every interface method name is present on the
    /// type (own methods only; the method table has no inheritance yet).
    fn satisfiesInterface(self: *const TypeChecker, ty: TypeIdx, iface_node: NodeIdx) bool {
        const sem = self.type_pool.get(ty);
        const decl_node: NodeIdx = switch (sem) {
            .struct_type => |n| n,
            else => return false,
        };
        const iface = self.arena.get(iface_node).interface_decl;
        const decl = self.arena.get(decl_node);
        const methods: []const NodeIdx = switch (decl.*) {
            .struct_decl => |s| s.methods.indices,
            else => return false,
        };
        outer: for (iface.methods.indices) |iface_method_idx| {
            const iface_method = self.arena.get(iface_method_idx);
            const want = self.nameSlice(iface_method.fn_decl.name);
            for (methods) |method_idx| {
                const method = self.arena.get(method_idx);
                if (method.* == .fn_decl and std.mem.eql(u8, self.nameSlice(method.fn_decl.name), want)) continue :outer;
            }
            return false;
        }
        return true;
    }

    /// Return type of a method call on a struct/class/interface, or null if
    /// the callee is not a method.
    fn inferMethodReturn(self: *TypeChecker, node_idx: NodeIdx, obj_ty: TypeIdx, field: []const u8) ?TypeIdx {
        var sem = self.type_pool.get(obj_ty);
        if (sem == .pointer) sem = self.type_pool.get(sem.pointer);

        var iface_node: ?NodeIdx = null;
        var decl_node: ?NodeIdx = null;
        switch (sem) {
            .struct_type => |n| decl_node = n,
            .interface_type => |n| iface_node = n,
            else => return null,
        }

        if (iface_node) |inode| {
            const iface = self.arena.get(inode).interface_decl;
            for (iface.methods.indices) |method_idx| {
                const method = self.arena.get(method_idx);
                if (method.* != .fn_decl) continue;
                if (std.mem.eql(u8, self.nameSlice(method.fn_decl.name), field)) {
                    if (method.fn_decl.return_type) |ret| return self.inferExprType(ret);
                    return self.void_ty;
                }
            }
            self.errorAt(node_idx, "interface has no method '{s}'", .{field});
            return null;
        }

        if (decl_node) |dnode| {
            const decl = self.arena.get(dnode);
            const methods: []const NodeIdx = switch (decl.*) {
                .struct_decl => |s| s.methods.indices,
                else => &.{},
            };
            for (methods) |method_idx| {
                const method = self.arena.get(method_idx);
                if (method.* != .fn_decl) continue;
                if (std.mem.eql(u8, self.nameSlice(method.fn_decl.name), field)) {
                    if (method.fn_decl.return_type) |ret| return self.inferExprType(ret);
                    return self.void_ty;
                }
            }
            self.errorAt(node_idx, "type has no method '{s}'", .{field});
            return null;
        }

        return null;
    }

    // ========================================================================
    // Enums and match
    // ========================================================================

    fn checkEnumVariantCall(self: *TypeChecker, node_idx: NodeIdx, vi: ast.EnumVariantInfo, c: anytype) void {
        const variant = self.arena.get(vi.variant_node);
        const field_count = variant.enum_variant.fields.indices.len;
        if (c.args.indices.len != field_count) {
            self.errorAt(node_idx, "variant '{s}' takes {d} arguments, got {d}", .{
                self.nameSlice(variant.enum_variant.name), field_count, c.args.indices.len,
            });
        }
        for (c.args.indices) |arg| {
            _ = self.inferExprType(arg);
        }
    }

    fn checkMatchStmt(self: *TypeChecker, stmt_idx: NodeIdx, m: anytype) anyerror!void {
        const scrut_ty = self.inferExprType(m.scrutinee);
        if (self.type_pool.get(scrut_ty) == .enum_type) {
            const enum_node = self.type_pool.get(scrut_ty).enum_type;
            for (m.arms.indices) |arm_idx| {
                _ = try self.checkEnumArm(arm_idx, enum_node);
            }
        } else {
            for (m.arms.indices) |arm_idx| {
                const arm = self.arena.get(arm_idx);
                _ = self.inferExprType(arm.match_arm.pattern);
                if (arm.match_arm.guard) |guard| {
                    _ = self.inferExprType(guard);
                }
                _ = self.inferExprType(arm.match_arm.body);
            }
        }
        self.setNodeType(stmt_idx, self.void_ty);
    }

    /// Check one enum match arm: verify the pattern names a variant of
    /// `enum_node`, bind its payload identifiers in an arm-local scope, and
    /// type the body. Returns the body's type (for expression-position
    /// matches).
    fn checkEnumArm(self: *TypeChecker, arm_idx: NodeIdx, enum_node: NodeIdx) anyerror!TypeIdx {
        const arm = self.arena.get(arm_idx);
        const pattern = self.arena.get(arm.match_arm.pattern);
        const variant = self.enumVariantFor(enum_node, pattern) orelse {
            self.errorAt(arm_idx, "match arm pattern must be a variant of this enum", .{});
            _ = self.inferExprType(arm.match_arm.pattern);
            return self.inferExprType(arm.match_arm.body);
        };

        _ = try self.scopes.pushScope(self.scopes.currentScope());
        const variant_node = self.arena.get(variant.variant_node);
        if (pattern.* == .call) {
            for (pattern.call.args.indices, 0..) |arg_idx, i| {
                if (i >= variant_node.enum_variant.fields.indices.len) break;
                const arg = self.arena.get(arg_idx);
                if (arg.* != .identifier) continue;
                const field_ty = self.inferExprType(variant_node.enum_variant.fields.indices[i]);
                self.scopes.insert(self.nameSlice(arg.identifier), .{
                    .name = arg.identifier,
                    .kind = .local,
                    .decl_node = arg_idx,
                    .type_idx = field_ty,
                }) catch @panic("OOM");
            }
        }
        _ = self.inferExprType(arm.match_arm.pattern);
        if (arm.match_arm.guard) |guard| {
            const guard_ty = self.inferExprType(guard);
            if (!self.typesEqual(guard_ty, self.bool_ty)) {
                self.errorAt(arm_idx, "match guard must be bool, got '{s}'", .{self.typeName(guard_ty)});
            }
        }
        const body_ty = self.inferExprType(arm.match_arm.body);
        self.scopes.popScope();
        return body_ty;
    }

    /// Match a pattern node against the variants of `enum_node`.
    fn enumVariantFor(self: *TypeChecker, enum_node: NodeIdx, pattern: *const Node) ?ast.EnumVariantInfo {
        const name: []const u8 = switch (pattern.*) {
            .identifier => |id| self.nameSlice(id),
            .call => |c| blk: {
                const callee = self.arena.get(c.func);
                if (callee.* != .identifier) return null;
                break :blk self.nameSlice(callee.identifier);
            },
            else => return null,
        };
        const vi = ast.findEnumVariant(self.arena, self.source, self.module_node, name) orelse return null;
        if (vi.enum_decl != enum_node) return null;
        return vi;
    }

    // ========================================================================
    // Indexing and iteration
    // ========================================================================

    /// Element type produced by `obj[index]`.
    fn inferElementType(self: *TypeChecker, node_idx: NodeIdx, obj_ty: TypeIdx) TypeIdx {
        var sem = self.type_pool.get(obj_ty);
        if (sem == .pointer) sem = self.type_pool.get(sem.pointer);
        return switch (sem) {
            .string_type => self.i32_ty,
            .array => |a| a.elem,
            .slice => |e| e,
            // A type name used as a generic application (`Option[i32]`) is
            // not real indexing: the application denotes the type itself.
            // Unresolved identifiers (e.g. `Slice[T]` inside a generic fn)
            // fall back to i32 until monomorphization lands.
            .struct_type, .class_type, .enum_type, .interface_type => obj_ty,
            .void, .inferred => self.i32_ty,
            else => blk: {
                self.errorAt(node_idx, "cannot index a value of type '{s}'", .{self.typeName(obj_ty)});
                break :blk self.void_ty;
            },
        };
    }

    /// Element type of a `for ... in` iterable, or void if not iterable.
    fn forEachElemType(self: *TypeChecker, node_idx: NodeIdx, iter_ty: TypeIdx) TypeIdx {
        var sem = self.type_pool.get(iter_ty);
        if (sem == .pointer) sem = self.type_pool.get(sem.pointer);
        return switch (sem) {
            .string_type => self.i32_ty,
            .array => |a| a.elem,
            .slice => |e| e,
            else => blk: {
                self.errorAt(node_idx, "'for ... in' requires a String, array or slice", .{});
                break :blk self.void_ty;
            },
        };
    }

    fn structFieldType(self: *TypeChecker, decl_node: NodeIdx, field_name: []const u8) ?TypeIdx {
        const s = self.arena.get(decl_node).struct_decl;
        for (s.fields.indices) |field_idx| {
            const field = self.arena.get(field_idx);
            if (std.mem.eql(u8, self.nameSlice(field.field.name), field_name)) {
                return self.inferTypeRefNode(field.field.ty);
            }
        }
        return null;
    }

    fn inferTypeRefNode(self: *TypeChecker, ty: ast.TypeRepr) TypeIdx {
        return switch (ty) {
            .plain => |n| self.inferExprType(n),
            .reference, .mut_reference => |n| blk: {
                const pointee = self.inferExprType(n);
                break :blk self.type_pool.add(.{ .pointer = pointee }) catch @panic("OOM");
            },
            .generic_app => |g| self.inferExprType(g.base),
        };
    }

    fn resolveDeclType(self: *TypeChecker, decl_node: NodeIdx) TypeIdx {
        const decl = self.arena.get(decl_node);
        switch (decl.*) {
            .fn_decl => {
                if (decl.fn_decl.return_type) |ret| {
                    return self.inferExprType(ret);
                }
                return self.void_ty;
            },
            .struct_decl => {
                return self.type_pool.add(.{ .struct_type = decl_node }) catch @panic("OOM");
            },
            .enum_decl => {
                return self.type_pool.add(.{ .enum_type = decl_node }) catch @panic("OOM");
            },
            .interface_decl => {
                return self.type_pool.add(.{ .interface_type = decl_node }) catch @panic("OOM");
            },
            .field => {
                return self.inferTypeRefNode(decl.field.ty);
            },
            .param => {
                return self.inferTypeRef(decl.param.ty);
            },
            .let_stmt => {
                if (decl.let_stmt.ty) |ty| {
                    return self.inferTypeRef(ty);
                }
                if (decl.let_stmt.init_expr) |init_val| {
                    return self.inferExprType(init_val);
                }
                return self.void_ty;
            },
            else => return self.void_ty,
        }
    }

    fn typesEqual(self: *const TypeChecker, a: TypeIdx, b: TypeIdx) bool {
        if (a == b) return true;
        const ta = self.type_pool.get(a);
        const tb = self.type_pool.get(b);
        return self.semTypesEqual(ta, tb);
    }

    fn semTypesEqual(self: *const TypeChecker, a: SemType, b: SemType) bool {
        if (@as(std.meta.Tag(SemType), a) != @as(std.meta.Tag(SemType), b)) return false;
        switch (a) {
            .void, .bool_type, .string_type, .inferred => return true,
            .int => |ai| return ai.signed == b.int.signed and ai.bits == b.int.bits,
            .float => |af| return af == b.float,
            .pointer => |ap| return self.typesEqual(ap, b.pointer),
            .function => |af| {
                const bf = b.function;
                if (!self.typesEqual(af.return_type, bf.return_type)) return false;
                if (af.param_types.len != bf.param_types.len) return false;
                for (af.param_types, bf.param_types) |pa, pb| {
                    if (!self.typesEqual(pa, pb)) return false;
                }
                return true;
            },
            .struct_type => |an| return an == b.struct_type,
            .class_type => |an| return an == b.class_type,
            .enum_type => |an| return an == b.enum_type,
            .array => |aa| {
                const ba = b.array;
                return self.typesEqual(aa.elem, ba.elem) and aa.size == ba.size;
            },
            .slice => |ae| return self.typesEqual(ae, b.slice),
            .interface_type => |an| return an == b.interface_type,
            .generic_param => |ag| return ag.index == b.generic_param.index,
        }
    }

    fn typeName(self: *TypeChecker, idx: TypeIdx) []const u8 {
        const t = self.type_pool.get(idx);
        return switch (t) {
            .int => |i| blk: {
                const buf = &self.type_name_buf[self.type_name_toggle];
                self.type_name_toggle ^= 1;
                break :blk std.fmt.bufPrint(buf, "{s}{d}", .{ if (i.signed) "i" else "u", i.bits }) catch "int";
            },
            .void => "void",
            .bool_type => "bool",
            .float => |f| @tagName(f),
            .pointer => "pointer",
            .function => "function",
            .string_type => "String",
            .struct_type => "struct",
            .class_type => "class",
            .enum_type => "enum",
            .array => "array",
            .slice => "slice",
            .interface_type => "interface",
            .generic_param => "generic",
            .inferred => "inferred",
        };
    }

    pub fn getNodeTypes(self: *const TypeChecker) []const TypeIdx {
        return self.node_types.items;
    }
};

fn tryStd(what: anyerror!void) void {
    what catch @panic("OOM");
}

fn tryStdTy(what: anyerror!TypeIdx) TypeIdx {
    return what catch @panic("OOM");
}

fn runCheck(allocator: Allocator, source: []const u8) !struct { arena: AstArena, type_pool: TypePool, diagnostics: diag.Diagnostics } {
    var arena = AstArena.init(allocator);
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    var parser = @import("../parser/parser.zig").Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    var type_pool = types_mod.TypePool.init(allocator);
    {
        var resolver = @import("resolve.zig").Resolver.init(allocator, &arena, source, &type_pool, &diags, module_node);
        defer resolver.deinit();
        try resolver.resolve();
        var checker = TypeChecker.init(allocator, &arena, source, &type_pool, &diags, &resolver.scopes, module_node);
        defer checker.deinit();
        try checker.check();
    }
    return .{ .arena = arena, .type_pool = type_pool, .diagnostics = diags };
}

test "typecheck: empty module" {
    var res = try runCheck(std.testing.allocator, "");
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: integer literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return 42
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: float literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> f64 {
        \\    return 3.14
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: string literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> String {
        \\    return "hello"
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: bool literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> bool {
        \\    return true
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: if expression" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    if true {
        \\        return 1
        \\    } else {
        \\        return 2
        \\    }
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: while loop" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    while s < 10 {
        \\        s = s + 1
        \\    }
        \\    return s
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: for range loop" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    for i in 0..10 {
        \\        s = s + i
        \\    }
        \\    return s
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: match expression" {
    var res = try runCheck(std.testing.allocator,
        \\fn check(x: i32) -> i32 {
        \\    match x {
        \\        1 => 10,
        \\        2 => 20,
        \\    }
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: function call" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    return add(1, 2)
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: let with type annotation" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let x: i32 = 42
        \\    return x
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: let with inferred type" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let z = 42
        \\    return z
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: struct field access" {
    var res = try runCheck(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn main() -> f64 {
        \\    let v: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
        \\    return v.x
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: comparison returns bool" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> bool {
        \\    return 1 < 2
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: print is an ordinary identifier until the prelude builtin lands" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print("hello")
        \\    return 42
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
}
