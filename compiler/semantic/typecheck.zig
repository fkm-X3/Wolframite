const std = @import("std");
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");
const prelude = @import("../prelude.zig");
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

/// What an inferred type placeholder stands for, for diagnostics.
const PendingKind = enum { param, closure_ret };

/// An unresolved type (R11b, "unification only"). A closure parameter or a
/// closure's inferred return type registers a per-binder `placeholder`
/// `TypeIdx`; `resolved` fills in the first time a concrete type is unified
/// against it.
const PendingType = struct {
    placeholder: TypeIdx,
    name: StringRef,
    kind: PendingKind,
    resolved: ?TypeIdx = null,
};

/// The resolved types of an operand pair after inference has been propagated
/// between them (a pending placeholder adopts its concrete sibling).
const UnifiedPair = struct {
    left: TypeIdx,
    right: TypeIdx,
};

/// Walking state for closure capture-set inference (R7): the captures found so
/// far (in source order of first appearance), the set of binders already
/// captured (dedup), and the names bound inside the closure, one set per lexical
/// level so an inner shadowing `let` never reads as a capture of an outer name.
const CaptureSet = struct {
    captured: std.ArrayListUnmanaged(NodeIdx) = .empty,
    seen: std.AutoHashMapUnmanaged(NodeIdx, void) = .empty,
    levels: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(void)) = .empty,

    fn deinit(self: *CaptureSet, allocator: Allocator) void {
        self.captured.deinit(allocator);
        self.seen.deinit(allocator);
        for (self.levels.items) |*level| level.deinit(allocator);
        self.levels.deinit(allocator);
    }

    fn pushLevel(self: *CaptureSet, allocator: Allocator) void {
        self.levels.append(allocator, .empty) catch @panic("OOM");
    }

    fn popLevel(self: *CaptureSet, allocator: Allocator) void {
        const last = self.levels.items.len - 1;
        self.levels.items[last].deinit(allocator);
        self.levels.items.len = last;
    }

    fn bind(self: *CaptureSet, allocator: Allocator, name: []const u8) void {
        self.levels.items[self.levels.items.len - 1].put(allocator, name, {}) catch @panic("OOM");
    }

    fn isBound(self: *CaptureSet, name: []const u8) bool {
        var i = self.levels.items.len;
        while (i > 0) {
            i -= 1;
            if (self.levels.items[i].contains(name)) return true;
        }
        return false;
    }
};

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

    /// Inference state for closures typed without annotations (R11b). Keyed by
    /// the binder: a closure parameter node, or the closure node itself for its
    /// inferred return type.
    pending: std.AutoHashMapUnmanaged(NodeIdx, PendingType),
    /// Reverse index: a placeholder `TypeIdx` -> the binder node behind it.
    pending_by_type: std.AutoHashMapUnmanaged(TypeIdx, NodeIdx),

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
            .pending = .empty,
            .pending_by_type = .empty,
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
        self.pending.deinit(self.allocator);
        self.pending_by_type.deinit(self.allocator);
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

    /// The type of a `void`-returning expression, for callers that need to
    /// compare against a call result.
    pub fn voidTypeIndex(self: *const TypeChecker) TypeIdx {
        return self.void_ty;
    }

    fn checkDecl(self: *TypeChecker, decl_idx: NodeIdx) anyerror!void {
        const decl = self.arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => try self.checkFnDecl(decl_idx),
            .enum_decl => try self.checkEnumDecl(decl_idx),
            else => {},
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
            const param_ty = self.inferTypeRef(param.param.ty);
            // Record the type on the binder so a closure that captures this
            // parameter can read it off the env entry (R7/R8).
            self.setNodeType(param_idx, param_ty);
            self.scopes.insert(self.nameSlice(param.param.name), .{
                .name = param.param.name,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = param_ty,
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

                const has_concrete_annotation = l.ty != null and self.isConcrete(declared_ty);
                if (l.init_expr) |init_val| {
                    // Thread the annotation down so an unannotated closure whose
                    // parameter types only the annotation fixes still infers
                    // (R11b). Doing this instead of a plain `inferExprType`
                    // keeps a closure init from erroring before it sees the
                    // expected signature.
                    const init_ty = if (has_concrete_annotation)
                        self.inferExprTypeExpected(init_val, declared_ty)
                    else
                        self.inferExprType(init_val);
                    if (has_concrete_annotation) {
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
                    // `expected` is the already-fixed return type, or the
                    // placeholder itself while an unannotated closure's return
                    // type is still open.
                    const expected = self.pendingResolved(self.fn_ret_type);
                    const val_ty = if (self.isConcrete(expected))
                        self.inferExprTypeExpected(val, expected)
                    else
                        self.inferExprType(val);
                    // The first concrete `return x` in an unannotated closure
                    // fixes that closure's return type (R11c).
                    if (self.isInferred(self.fn_ret_type) and self.isConcrete(val_ty)) {
                        self.resolvePlaceholder(self.fn_ret_type, val_ty);
                    }
                    const fixed = self.pendingResolved(self.fn_ret_type);
                    if (!self.typesEqual(val_ty, fixed)) {
                        self.errorAt(stmt_idx, "return type mismatch: expected '{s}' but got '{s}'", .{
                            self.typeName(fixed), self.typeName(val_ty),
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
                    // A read of a closure parameter whose type is still being
                    // inferred joins that parameter's unification set (R11b).
                    if (sym.kind == .param) {
                        if (self.pending.get(sym.decl_node)) |p| {
                            return p.resolved orelse p.placeholder;
                        }
                    }
                    if (sym.type_idx != TypeIdx.none) {
                        return sym.type_idx;
                    }
                    return self.resolveDeclType(sym.decl_node);
                }
                return self.void_ty;
            },
            .binary_op => |b| {
                // Propagate an unresolved closure-parameter placeholder between
                // the operands before comparing them (R11b, "unification only").
                const left_raw = self.inferExprType(b.left);
                const right_raw = self.inferExprType(b.right);
                const unified = self.unifyOperands(left_raw, right_raw);
                const left_ty = unified.left;
                const right_ty = unified.right;

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
            .generic_app => |ga| {
                // `Pair[i32, f64]`: the arguments are type references and the
                // application denotes the applied type itself until
                // monomorphization resolves the substitution.
                _ = self.inferExprType(ga.base);
                for (ga.args.indices) |arg| {
                    _ = self.inferExprType(arg);
                }
                return self.inferExprType(ga.base);
            },
            .paren_expr => |p| {
                return self.inferExprType(p);
            },
            .fn_type => |ft| {
                const params = self.allocator.alloc(TypeIdx, ft.params.indices.len) catch @panic("OOM");
                defer self.allocator.free(params);
                for (ft.params.indices, 0..) |param_ty, i| {
                    params[i] = self.inferTypeRef(param_ty);
                }
                return self.functionType(params, self.inferTypeRef(ft.return_type));
            },
            .fn_ref => |id| {
                const name = self.nameSlice(id);
                const sym = self.scopes.lookup(name, self.scopes.currentScope());
                if (sym == null or sym.?.kind != .function) {
                    self.errorAt(expr_idx, "'{s}' is not a function", .{name});
                    return self.void_ty;
                }
                return self.fnSignatureType(sym.?.decl_node);
            },
            .struct_init => |si| {
                return self.inferStructInit(expr_idx, si);
            },
            .range_expr => |r| {
                _ = self.inferExprType(r.start);
                _ = self.inferExprType(r.end);
                return self.i32_ty;
            },
            .closure => |cl| {
                return self.inferClosureType(expr_idx, cl, null);
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
                return self.inferPipeline(expr_idx, p);
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

    /// The `function` type for a signature. `params` is copied into a slice
    /// owned by the type pool.
    fn functionType(self: *TypeChecker, params: []const TypeIdx, return_type: TypeIdx) TypeIdx {
        const owned = self.allocator.alloc(TypeIdx, params.len) catch @panic("OOM");
        @memcpy(owned, params);
        return self.type_pool.add(.{ .function = .{
            .param_types = owned,
            .return_type = return_type,
        } }) catch @panic("OOM");
    }

    /// The `function` type of a declared `fn`, built from its parameters and
    /// return annotation. The reference itself carries no capture environment.
    fn fnSignatureType(self: *TypeChecker, fn_idx: NodeIdx) TypeIdx {
        const f = self.arena.get(fn_idx).fn_decl;
        const params = self.allocator.alloc(TypeIdx, f.params.indices.len) catch @panic("OOM");
        defer self.allocator.free(params);
        for (f.params.indices, 0..) |param_idx, i| {
            const param = self.arena.get(param_idx);
            params[i] = self.inferTypeRef(param.param.ty);
        }
        const return_type: TypeIdx = if (f.return_type) |ret| self.inferTypeRef(ret) else self.void_ty;
        return self.functionType(params, return_type);
    }

    // ========================================================================
    // Inference and unification (R11b)
    // ========================================================================

    /// A fresh unresolved placeholder. Each call makes a distinct `TypeIdx`, so
    /// it can stand for exactly one binder in the inference maps.
    fn freshInferred(self: *TypeChecker) TypeIdx {
        return self.type_pool.add(.inferred) catch @panic("OOM");
    }

    /// Register a binder whose type is not yet known: a closure parameter node,
    /// or a closure node for its inferred return type.
    fn registerPending(self: *TypeChecker, binder: NodeIdx, name: StringRef, kind: PendingKind) TypeIdx {
        const placeholder = self.freshInferred();
        self.pending.put(self.allocator, binder, .{
            .placeholder = placeholder,
            .name = name,
            .kind = kind,
        }) catch @panic("OOM");
        self.pending_by_type.put(self.allocator, placeholder, binder) catch @panic("OOM");
        return placeholder;
    }

    /// Give a placeholder a concrete type the first time one is unified against
    /// it, and rewrite every cached node type that still names it so later reads
    /// see the concrete type (R11b, "unification only"). Resolution is
    /// first-wins: a later unify against an already-resolved binder is ignored.
    fn resolvePlaceholder(self: *TypeChecker, placeholder: TypeIdx, concrete: TypeIdx) void {
        if (!self.isInferred(placeholder) or !self.isConcrete(concrete)) return;
        if (self.pending_by_type.get(placeholder)) |binder| {
            if (self.pending.getPtr(binder)) |p| {
                if (p.resolved != null) return;
                p.resolved = concrete;
            }
        }
        for (self.node_types.items) |*nt| {
            if (nt.* == placeholder) nt.* = concrete;
        }
    }

    fn isInferred(self: *const TypeChecker, ty: TypeIdx) bool {
        return self.type_pool.get(ty) == .inferred;
    }

    /// The concrete type a binder's placeholder resolved to, or `ty` itself when
    /// it is not an unresolved placeholder. Lets a reader that still holds the
    /// placeholder compare against the fixed type.
    fn pendingResolved(self: *const TypeChecker, ty: TypeIdx) TypeIdx {
        if (!self.isInferred(ty)) return ty;
        const binder = self.pending_by_type.get(ty) orelse return ty;
        const p = self.pending.get(binder) orelse return ty;
        return p.resolved orelse ty;
    }

    /// Whether a type is known well enough to unify or thread. `.inferred` is
    /// the only not-yet-known type; every other `SemType` is concrete.
    fn isConcrete(self: *const TypeChecker, ty: TypeIdx) bool {
        return !self.isInferred(ty);
    }

    /// Propagate an unresolved placeholder between two operands: if one side is
    /// pending and the other concrete, the placeholder adopts the concrete type
    /// (R11b, "unification only"). A pair of unresolved placeholders stays
    /// unresolved, which is what makes an untypable closure body an error.
    fn unifyOperands(self: *TypeChecker, left_ty: TypeIdx, right_ty: TypeIdx) UnifiedPair {
        if (self.isInferred(left_ty) and self.isConcrete(right_ty)) {
            self.resolvePlaceholder(left_ty, right_ty);
            return .{ .left = right_ty, .right = right_ty };
        }
        if (self.isInferred(right_ty) and self.isConcrete(left_ty)) {
            self.resolvePlaceholder(right_ty, left_ty);
            return .{ .left = left_ty, .right = left_ty };
        }
        return .{ .left = left_ty, .right = right_ty };
    }

    /// Infer `expr_idx` with an expected type, threading it into closure params
    /// (R11a). For anything but a closure this is a plain inference plus, when
    /// the expression is an unresolved placeholder, adopting the expected type.
    fn inferExprTypeExpected(self: *TypeChecker, expr_idx: NodeIdx, expected: TypeIdx) TypeIdx {
        const prev = self.getNodeType(expr_idx);
        if (prev != self.void_ty) return prev;

        const expr = self.arena.get(expr_idx);
        if (expr.* == .closure) {
            const ty = self.inferClosureType(expr_idx, expr.closure, expected);
            self.setNodeType(expr_idx, ty);
            return ty;
        }
        const ty = self.inferExprType(expr_idx);
        if (self.isInferred(ty) and self.isConcrete(expected)) {
            self.resolvePlaceholder(ty, expected);
            return expected;
        }
        return ty;
    }

    /// Type a struct literal and check each provided field against its declared
    /// type. Generic struct fields (generic params not yet substituted) are left
    /// unchecked until monomorphization (R25).
    fn inferStructInit(self: *TypeChecker, expr_idx: NodeIdx, si: anytype) TypeIdx {
        const ty = self.inferExprType(si.ty);
        const sem = self.type_pool.get(ty);
        if (sem != .struct_type) {
            for (si.fields.indices) |field_idx| {
                _ = self.inferExprType(self.arena.get(field_idx).struct_init_field.value);
            }
            return ty;
        }
        const decl_node = sem.struct_type;
        const is_generic = self.arena.get(decl_node).struct_decl.generic_params.indices.len > 0;
        for (si.fields.indices) |field_idx| {
            const f = self.arena.get(field_idx).struct_init_field;
            const field_name = self.nameSlice(f.name);
            const expected = self.structFieldType(decl_node, field_name);
            if (expected) |et| {
                if (!is_generic and et != self.void_ty) {
                    const got = self.inferExprTypeExpected(f.value, et);
                    if (!self.typesEqual(et, got)) {
                        self.errorAt(expr_idx, "field '{s}' expects '{s}' but got '{s}'", .{
                            field_name, self.typeName(et), self.typeName(got),
                        });
                    }
                } else {
                    _ = self.inferExprType(f.value);
                }
            } else {
                _ = self.inferExprType(f.value);
                self.errorAt(expr_idx, "struct has no field '{s}'", .{field_name});
            }
        }
        return ty;
    }

    /// Type a closure literal: infer its captured set (R7), its parameter types
    /// (R11b), and its return type (R11c). `expected`, when present, is the
    /// context's `function` type and fixes unannotated params and the return
    /// (R11a).
    fn inferClosureType(self: *TypeChecker, expr_idx: NodeIdx, cl: anytype, expected: ?TypeIdx) TypeIdx {
        var expected_params: []const TypeIdx = &.{};
        var expected_ret: ?TypeIdx = null;
        if (expected) |e| {
            if (self.type_pool.get(e) == .function) {
                const ef = self.type_pool.get(e).function;
                expected_params = ef.param_types;
                if (ef.return_type != self.void_ty) expected_ret = ef.return_type;
            }
        }
        if (expected_params.len != 0 and expected_params.len != cl.params.indices.len) {
            self.errorAt(expr_idx, "closure has {d} parameter(s) but is expected to have {d}", .{
                cl.params.indices.len, expected_params.len,
            });
        }

        // Capture set, in source order of first appearance (R7b). Collected
        // before the closure's own params are scoped so a free name resolves to
        // its enclosing binding, not to the closure parameter of the same name.
        const env = self.collectCaptures(cl);

        const param_types = self.allocator.alloc(TypeIdx, cl.params.indices.len) catch @panic("OOM");
        defer self.allocator.free(param_types);
        for (cl.params.indices, 0..) |param_idx, i| {
            const pnode = self.arena.get(param_idx).param;
            const ty: TypeIdx = if (pnode.ty != NodeIdx.none)
                self.inferTypeRef(pnode.ty)
            else if (i < expected_params.len and expected_params[i] != self.void_ty)
                expected_params[i]
            else
                self.registerPending(param_idx, pnode.name, .param);
            param_types[i] = ty;
            self.setNodeType(param_idx, ty);
        }

        var ret_ty: TypeIdx = self.void_ty;
        var ret_placeholder: ?TypeIdx = null;
        if (expected_ret) |r| {
            ret_ty = r;
        } else {
            const ph = self.registerPending(expr_idx, .{ .start = 0, .end = 0 }, .closure_ret);
            ret_placeholder = ph;
            ret_ty = ph;
        }

        const prev_ret = self.fn_ret_type;
        const prev_in_fn = self.in_function;
        self.fn_ret_type = ret_ty;
        self.in_function = true;

        _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
        for (cl.params.indices, 0..) |param_idx, i| {
            const pname = self.arena.get(param_idx).param.name;
            self.scopes.insert(self.nameSlice(pname), .{
                .name = pname,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = param_types[i],
            }) catch @panic("OOM");
        }

        const body_is_block = self.arena.get(cl.body).* == .block;
        const body_ty = self.inferExprType(cl.body);

        self.scopes.popScope();
        self.fn_ret_type = prev_ret;
        self.in_function = prev_in_fn;

        if (ret_placeholder) |ph| {
            // An expression body's type is the closure's return type; a block
            // body's explicit `return`s already fixed it, and a body with no
            // return is `void`. Resolution is first-wins, so a fixed return is
            // never overwritten.
            if (self.isConcrete(body_ty)) self.resolvePlaceholder(ph, body_ty);
            ret_ty = if (self.pending.get(expr_idx)) |p| (p.resolved orelse ph) else body_ty;
        } else if (!body_is_block and !self.typesEqual(ret_ty, body_ty)) {
            self.errorAt(expr_idx, "closure body has type '{s}' but is expected to return '{s}'", .{
                self.typeName(body_ty), self.typeName(ret_ty),
            });
        }

        // A parameter with no annotation and no expected type is only okay if
        // the body fixed it (R11b).
        for (cl.params.indices, 0..) |param_idx, i| {
            if (self.pending.get(param_idx)) |p| {
                if (p.resolved) |r| {
                    param_types[i] = r;
                } else {
                    self.errorAt(param_idx, "cannot infer parameter type of closure parameter '{s}'", .{
                        self.nameSlice(p.name),
                    });
                    param_types[i] = self.void_ty;
                }
            }
        }

        self.arena.set(expr_idx, .{ .closure = .{ .params = cl.params, .body = cl.body, .env = env } });
        return self.functionType(param_types, ret_ty);
    }

    /// Walk a closure body and return the env `NodeList` of captured binding
    /// declaration nodes (R7). Module-level functions, type names, variants, and
    /// the closure's own bindings are not captured.
    fn collectCaptures(self: *TypeChecker, cl: anytype) NodeList {
        var cs = CaptureSet{};
        defer cs.deinit(self.allocator);
        cs.pushLevel(self.allocator);
        for (cl.params.indices) |param_idx| {
            cs.bind(self.allocator, self.nameSlice(self.arena.get(param_idx).param.name));
        }
        self.walkCaptures(cl.body, &cs);
        return self.arena.allocNodeList(cs.captured.items) catch @panic("OOM");
    }

    fn addCapture(self: *TypeChecker, cs: *CaptureSet, sym: scope_mod.Symbol) void {
        const gop = cs.seen.getOrPut(self.allocator, sym.decl_node) catch @panic("OOM");
        if (gop.found_existing) return;
        cs.captured.append(self.allocator, sym.decl_node) catch @panic("OOM");
    }

    fn captureIdentifier(self: *TypeChecker, node_idx: NodeIdx, cs: *CaptureSet) void {
        const name = self.nameSlice(self.arena.get(node_idx).identifier);
        if (std.mem.eql(u8, name, "_")) return;
        if (cs.isBound(name)) return;
        if (self.builtinTypeName(name) != null) return;
        if (ast.findEnumVariant(self.arena, self.source, self.module_node, name) != null) return;
        const sym = self.scopes.lookup(name, self.scopes.currentScope()) orelse return;
        switch (sym.kind) {
            // A free value binding, or a generic param captured like a value
            // (R7d). Static entities (functions, types, modules, prelude) are
            // not captured (R7c).
            .local, .param, .generic_param => self.addCapture(cs, sym),
            else => {},
        }
    }

    fn walkMatchArm(self: *TypeChecker, arm_idx: NodeIdx, cs: *CaptureSet) void {
        const arm = self.arena.get(arm_idx).match_arm;
        cs.pushLevel(self.allocator);
        const pattern = self.arena.get(arm.pattern);
        if (pattern.* == .call) {
            // Payload identifiers are bindings for the arm body; the callee is a
            // variant name and is never captured.
            for (pattern.call.args.indices) |arg_idx| {
                const arg = self.arena.get(arg_idx);
                if (arg.* == .identifier) {
                    cs.bind(self.allocator, self.nameSlice(arg.identifier));
                } else {
                    self.walkCaptures(arg_idx, cs);
                }
            }
        } else {
            self.walkCaptures(arm.pattern, cs);
        }
        if (arm.guard) |g| self.walkCaptures(g, cs);
        self.walkCaptures(arm.body, cs);
        cs.popLevel(self.allocator);
    }

    fn walkCaptures(self: *TypeChecker, node_idx: NodeIdx, cs: *CaptureSet) void {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .identifier => self.captureIdentifier(node_idx, cs),
            .binary_op => |b| {
                self.walkCaptures(b.left, cs);
                self.walkCaptures(b.right, cs);
            },
            .unary_op => |u| self.walkCaptures(u.operand, cs),
            .call => |c| {
                self.walkCaptures(c.func, cs);
                for (c.args.indices) |a| self.walkCaptures(a, cs);
            },
            .field_access => |fa| self.walkCaptures(fa.object, cs),
            .index_access => |ia| {
                self.walkCaptures(ia.object, cs);
                self.walkCaptures(ia.index, cs);
            },
            .generic_app => |ga| {
                self.walkCaptures(ga.base, cs);
                for (ga.args.indices) |a| self.walkCaptures(a, cs);
            },
            .paren_expr => |p| self.walkCaptures(p, cs),
            .struct_init => |si| {
                self.walkCaptures(si.ty, cs);
                for (si.fields.indices) |f| {
                    self.walkCaptures(self.arena.get(f).struct_init_field.value, cs);
                }
            },
            .range_expr => |r| {
                self.walkCaptures(r.start, cs);
                self.walkCaptures(r.end, cs);
            },
            .fn_type => |ft| {
                for (ft.params.indices) |p| self.walkCaptures(p, cs);
                self.walkCaptures(ft.return_type, cs);
            },
            .closure => |cl| {
                cs.pushLevel(self.allocator);
                for (cl.params.indices) |param_idx| {
                    cs.bind(self.allocator, self.nameSlice(self.arena.get(param_idx).param.name));
                }
                self.walkCaptures(cl.body, cs);
                cs.popLevel(self.allocator);
            },
            .comptime_block, .comptime_expr => |inner| self.walkCaptures(inner, cs),
            .comptime_call => |cc| {
                for (cc.args.indices) |a| self.walkCaptures(a, cs);
            },
            .pipeline => |p| {
                self.walkCaptures(p.lhs, cs);
                self.walkCaptures(p.rhs, cs);
            },
            .try_propagate, .move_expr => |inner| self.walkCaptures(inner, cs),
            .region_expr => |r| {
                if (r.allocator) |a| self.walkCaptures(a, cs);
                self.walkCaptures(r.body, cs);
            },
            .block => |b| {
                cs.pushLevel(self.allocator);
                for (b.stmts.indices) |s| self.walkCaptures(s, cs);
                cs.popLevel(self.allocator);
            },
            .if_expr => |i| {
                self.walkCaptures(i.cond, cs);
                self.walkCaptures(i.then_body, cs);
                if (i.else_body) |e| self.walkCaptures(e, cs);
            },
            .while_expr => |w| {
                self.walkCaptures(w.cond, cs);
                self.walkCaptures(w.body, cs);
            },
            .for_range => |fr| {
                self.walkCaptures(fr.start, cs);
                self.walkCaptures(fr.end, cs);
                cs.pushLevel(self.allocator);
                cs.bind(self.allocator, self.nameSlice(fr.var_name));
                self.walkCaptures(fr.body, cs);
                cs.popLevel(self.allocator);
            },
            .for_each => |fe| {
                self.walkCaptures(fe.iterable, cs);
                cs.pushLevel(self.allocator);
                cs.bind(self.allocator, self.nameSlice(fe.var_name));
                self.walkCaptures(fe.body, cs);
                cs.popLevel(self.allocator);
            },
            .match_expr => |m| {
                self.walkCaptures(m.scrutinee, cs);
                for (m.arms.indices) |arm_idx| self.walkMatchArm(arm_idx, cs);
            },
            .let_stmt => |l| {
                if (l.ty) |t| self.walkCaptures(t, cs);
                if (l.init_expr) |e| self.walkCaptures(e, cs);
                cs.bind(self.allocator, self.nameSlice(l.name));
            },
            .return_stmt => |r| {
                if (r.value) |v| self.walkCaptures(v, cs);
            },
            .expr_stmt => |e| self.walkCaptures(e.expr, cs),
            .defer_stmt => |d| self.walkCaptures(d.expr, cs),
            else => {},
        }
    }

    // ========================================================================
    // Calls
    // ========================================================================

    /// Type of a call expression: a direct call to a named `fn`, a prelude call,
    /// an enum variant constructor (`Some(x)`), or a call through a fn value
    /// (`f(x)` where `f` holds a `fn(...)`). There is no method dispatch —
    /// `recv.f(...)` is a field read typed by `inferExprType`, then a fn-value
    /// call.
    fn inferCallType(self: *TypeChecker, expr_idx: NodeIdx, c: anytype) TypeIdx {
        const callee = self.arena.get(c.func);
        if (callee.* == .identifier) {
            const name = self.nameSlice(callee.identifier);
            if (ast.findEnumVariant(self.arena, self.source, self.module_node, name)) |vi| {
                return self.checkEnumVariantCall(expr_idx, vi, c.args);
            }
            if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                switch (sym.kind) {
                    .prelude_fn => return self.checkPreludeCall(expr_idx, sym, c.args, null, null),
                    .function => return self.checkDirectCall(expr_idx, sym, c.args),
                    else => return self.checkFnValueCall(expr_idx, c),
                }
            }
            // An undefined callee: the resolver already reported it, so type
            // the arguments and produce no value rather than a second error.
            for (c.args.indices) |arg| _ = self.inferExprType(arg);
            return self.void_ty;
        }
        return self.checkFnValueCall(expr_idx, c);
    }

    /// Type a call to a declared `fn` by name (R14a, no env at the call site).
    fn checkDirectCall(self: *TypeChecker, node_idx: NodeIdx, sym: scope_mod.Symbol, args: NodeList) TypeIdx {
        const sig = self.fnSignatureType(sym.decl_node);
        const f = self.type_pool.get(sig).function;
        self.checkArgList(node_idx, f.param_types, args, null, null);
        return f.return_type;
    }

    /// Type a call through a fn value (`f(x)` where `f` is a local, a field, or
    /// any expression of `function` type). This is the call-through-ptr form
    /// (R14b): the callee's visible signature drives arity and argument typing.
    fn checkFnValueCall(self: *TypeChecker, expr_idx: NodeIdx, c: anytype) TypeIdx {
        const callee_ty = self.inferExprType(c.func);
        const sem = self.type_pool.get(callee_ty);
        if (sem == .function) {
            self.checkArgList(expr_idx, sem.function.param_types, c.args, null, null);
            return sem.function.return_type;
        }
        for (c.args.indices) |arg| _ = self.inferExprType(arg);
        self.errorAt(expr_idx, "cannot call a value of type '{s}'", .{self.typeName(callee_ty)});
        return self.void_ty;
    }

    /// Check an argument list against a parameter-type list, optionally with a
    /// piped value replacing a `_` hole (R30a) or prepended as argument 0
    /// (R30b). Each argument is inferred with its expected type so a closure
    /// argument infers its parameters (R11a).
    fn checkArgList(
        self: *TypeChecker,
        node_idx: NodeIdx,
        param_types: []const TypeIdx,
        args: NodeList,
        piped: ?NodeIdx,
        hole: ?usize,
    ) void {
        const effective = args.indices.len + (if (piped != null and hole == null) @as(usize, 1) else 0);
        if (param_types.len != effective) {
            self.errorAt(node_idx, "call has {d} arguments but the function takes {d}", .{
                effective, param_types.len,
            });
        }

        var pi: usize = 0;
        if (piped != null and hole == null) {
            self.checkOneArg(node_idx, param_types, pi, piped.?);
            pi += 1;
        }
        var ai: usize = 0;
        while (ai < args.indices.len) : (ai += 1) {
            if (hole) |h| {
                if (ai == h) {
                    self.checkOneArg(node_idx, param_types, pi, piped.?);
                    pi += 1;
                    continue;
                }
            }
            self.checkOneArg(node_idx, param_types, pi, args.indices[ai]);
            pi += 1;
        }
    }

    /// Check one argument against parameter `pi` (if a parameter exists),
    /// threading the expected type into a closure argument (R11a/R11b).
    fn checkOneArg(self: *TypeChecker, node_idx: NodeIdx, param_types: []const TypeIdx, pi: usize, arg: NodeIdx) void {
        if (self.isHole(arg)) {
            self.errorAt(node_idx, "'_' hole outside a pipeline", .{});
            return;
        }
        if (pi >= param_types.len) {
            _ = self.inferExprType(arg);
            return;
        }
        const et = param_types[pi];
        if (et != self.void_ty) {
            const got = self.inferExprTypeExpected(arg, et);
            if (!self.typesEqual(et, got)) {
                self.errorAt(node_idx, "argument {d} expects '{s}' but got '{s}'", .{
                    pi + 1, self.typeName(et), self.typeName(got),
                });
            }
        } else {
            _ = self.inferExprType(arg);
        }
    }

    /// Type a prelude call against its roster signature. A prelude entry has no
    /// AST declaration, so arity and argument types are read off the roster row.
    /// `piped`/`hole` carry pipeline desugaring (R30) for `x |> print(...)`.
    fn checkPreludeCall(
        self: *TypeChecker,
        node_idx: NodeIdx,
        sym: scope_mod.Symbol,
        args: NodeList,
        piped: ?NodeIdx,
        hole: ?usize,
    ) TypeIdx {
        if (sym.prelude.index >= prelude.roster.len) {
            self.errorAt(node_idx, "prelude function '{s}' is not in the roster", .{
                sym.displayName(self.source),
            });
            return self.void_ty;
        }
        const entry = prelude.roster[sym.prelude.index];
        const name = entry.name;

        const effective = args.indices.len + (if (piped != null and hole == null) @as(usize, 1) else 0);
        if (entry.params.len != effective) {
            self.errorAt(node_idx, "'{s}' takes {d} argument(s), got {d}", .{
                name, entry.params.len, effective,
            });
            for (args.indices) |arg| _ = self.inferExprType(arg);
            if (piped) |p| _ = self.inferExprType(p);
            return self.typeForParam(entry.return_type);
        }

        var pi: usize = 0;
        if (piped != null and hole == null) {
            self.checkPreludeArg(node_idx, name, entry, pi, piped.?);
            pi += 1;
        }
        var ai: usize = 0;
        while (ai < args.indices.len) : (ai += 1) {
            if (hole) |h| {
                if (ai == h) {
                    self.checkPreludeArg(node_idx, name, entry, pi, piped.?);
                    pi += 1;
                    continue;
                }
            }
            self.checkPreludeArg(node_idx, name, entry, pi, args.indices[ai]);
            pi += 1;
        }

        return self.typeForParam(entry.return_type);
    }

    fn checkPreludeArg(self: *TypeChecker, node_idx: NodeIdx, name: []const u8, entry: prelude.PreludeFn, pi: usize, arg: NodeIdx) void {
        if (self.isHole(arg)) {
            self.errorAt(node_idx, "'_' hole outside a pipeline", .{});
            return;
        }
        const want = entry.params[pi];
        if (want == .void) {
            self.errorAt(node_idx, "'{s}' takes no arguments", .{name});
            return;
        }
        const want_ty = self.typeForParam(want);
        const got_ty = self.inferExprTypeExpected(arg, want_ty);
        if (!self.typesEqual(want_ty, got_ty)) {
            self.errorAt(node_idx, "'{s}' expects '{s}', got '{s}'", .{
                name, self.typeName(want_ty), self.typeName(got_ty),
            });
        }
    }

    fn typeForParam(self: *const TypeChecker, param: prelude.ParamType) TypeIdx {
        return switch (param) {
            .string => self.string_ty,
            .i64 => self.i64_ty,
            .u64 => self.u64_ty,
            .f64 => self.f64_ty,
            .void => self.void_ty,
        };
    }

    // ========================================================================
    // Pipelines
    // ========================================================================

    fn isHole(self: *TypeChecker, node_idx: NodeIdx) bool {
        const n = self.arena.get(node_idx);
        return n.* == .identifier and std.mem.eql(u8, self.nameSlice(n.identifier), "_");
    }

    /// Type `lhs |> rhs` (R30). The pipeline's type is the callee's return type;
    /// the piped value replaces the single `_` hole, or is prepended as
    /// argument 0, or is the sole argument of a bare fn value.
    fn inferPipeline(self: *TypeChecker, expr_idx: NodeIdx, p: anytype) TypeIdx {
        const rhs = self.arena.get(p.rhs);
        if (rhs.* == .call) {
            const c = rhs.call;
            var hole: ?usize = null;
            var holes: usize = 0;
            for (c.args.indices, 0..) |arg, i| {
                if (self.isHole(arg)) {
                    hole = i;
                    holes += 1;
                }
            }
            if (holes > 1) {
                self.errorAt(expr_idx, "a piped call may have at most one '_' hole", .{});
            }
            return self.checkPipedCall(expr_idx, c, p.lhs, hole);
        }
        return self.checkPipedValue(expr_idx, p.rhs, p.lhs);
    }

    fn checkPipedCall(self: *TypeChecker, node_idx: NodeIdx, c: anytype, piped: NodeIdx, hole: ?usize) TypeIdx {
        const callee = self.arena.get(c.func);
        if (callee.* == .identifier) {
            const name = self.nameSlice(callee.identifier);
            if (ast.findEnumVariant(self.arena, self.source, self.module_node, name)) |vi| {
                const variant = self.arena.get(vi.variant_node);
                const fields = variant.enum_variant.fields;
                const ptypes = self.allocator.alloc(TypeIdx, fields.indices.len) catch @panic("OOM");
                defer self.allocator.free(ptypes);
                for (fields.indices, 0..) |f, i| ptypes[i] = self.inferExprType(f);
                self.checkArgList(node_idx, ptypes, c.args, piped, hole);
                return self.type_pool.add(.{ .enum_type = vi.enum_decl }) catch self.void_ty;
            }
            if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                switch (sym.kind) {
                    .prelude_fn => return self.checkPreludeCall(node_idx, sym, c.args, piped, hole),
                    .function => {
                        const sig = self.fnSignatureType(sym.decl_node);
                        const f = self.type_pool.get(sig).function;
                        self.checkArgList(node_idx, f.param_types, c.args, piped, hole);
                        return f.return_type;
                    },
                    else => {},
                }
            }
        }

        const callee_ty = self.inferExprType(c.func);
        const sem = self.type_pool.get(callee_ty);
        if (sem == .function) {
            self.checkArgList(node_idx, sem.function.param_types, c.args, piped, hole);
            return sem.function.return_type;
        }
        _ = self.inferExprType(piped);
        for (c.args.indices) |a| _ = self.inferExprType(a);
        self.errorAt(node_idx, "cannot pipe into a value of type '{s}'", .{self.typeName(callee_ty)});
        return self.void_ty;
    }

    /// `lhs |> rhs` where `rhs` is a bare fn value: `lhs` is its single
    /// argument (R30c).
    fn checkPipedValue(self: *TypeChecker, node_idx: NodeIdx, rhs: NodeIdx, piped: NodeIdx) TypeIdx {
        const rhs_ty = self.inferExprType(rhs);
        const sem = self.type_pool.get(rhs_ty);
        if (sem == .function) {
            const f = sem.function;
            if (f.param_types.len >= 1 and f.param_types[0] != self.void_ty) {
                const got = self.inferExprTypeExpected(piped, f.param_types[0]);
                if (!self.typesEqual(f.param_types[0], got)) {
                    self.errorAt(node_idx, "piped value expects '{s}' but got '{s}'", .{
                        self.typeName(f.param_types[0]), self.typeName(got),
                    });
                }
            } else {
                _ = self.inferExprType(piped);
            }
            return f.return_type;
        }
        _ = self.inferExprType(piped);
        self.errorAt(node_idx, "cannot pipe into a value of type '{s}'", .{self.typeName(rhs_ty)});
        return self.void_ty;
    }

    // ========================================================================
    // Enums and match
    // ========================================================================

    /// Type an enum variant constructor `Some(x)` and return the enum type.
    /// Payload arguments are checked against the declared field types.
    fn checkEnumVariantCall(self: *TypeChecker, node_idx: NodeIdx, vi: ast.EnumVariantInfo, args: NodeList) TypeIdx {
        const variant = self.arena.get(vi.variant_node);
        const fields = variant.enum_variant.fields;
        if (args.indices.len != fields.indices.len) {
            self.errorAt(node_idx, "variant '{s}' takes {d} arguments, got {d}", .{
                self.nameSlice(variant.enum_variant.name), fields.indices.len, args.indices.len,
            });
        }
        for (args.indices, 0..) |arg, i| {
            if (i < fields.indices.len) {
                const field_ty = self.inferExprType(fields.indices[i]);
                if (field_ty != self.void_ty) {
                    const got = self.inferExprTypeExpected(arg, field_ty);
                    if (!self.typesEqual(field_ty, got)) {
                        self.errorAt(node_idx, "variant field {d} expects '{s}' but got '{s}'", .{
                            i + 1, self.typeName(field_ty), self.typeName(got),
                        });
                    }
                } else {
                    _ = self.inferExprType(arg);
                }
            } else {
                _ = self.inferExprType(arg);
            }
        }
        return self.type_pool.add(.{ .enum_type = vi.enum_decl }) catch self.void_ty;
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
            .struct_type, .enum_type => obj_ty,
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
            .enum_type => |an| return an == b.enum_type,
            .array => |aa| {
                const ba = b.array;
                return self.typesEqual(aa.elem, ba.elem) and aa.size == ba.size;
            },
            .slice => |ae| return self.typesEqual(ae, b.slice),
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
            .enum_type => "enum",
            .array => "array",
            .slice => "slice",
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

const CheckRun = struct {
    arena: AstArena,
    type_pool: TypePool,
    diagnostics: diag.Diagnostics,
};

fn runCheck(allocator: Allocator, source: []const u8) !CheckRun {
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

fn deinitCheck(res: *CheckRun) void {
    res.arena.deinit();
    res.type_pool.deinit();
    res.diagnostics.deinit();
}

/// Whether any diagnostic message contains `needle`. Used to pin the wording of
/// the prelude's own diagnostics without depending on unrelated ones.
fn hasMessage(diagnostics: *const diag.Diagnostics, needle: []const u8) bool {
    for (diagnostics.items.items) |item| {
        if (std.mem.indexOf(u8, item.message, needle) != null) return true;
    }
    return false;
}

/// The index of the AST node holding the `print(...)` call in `source`, if any.
fn findPrintCall(arena: *const AstArena, source: []const u8) ?NodeIdx {
    for (arena.nodes.items, 0..) |node, i| {
        if (node != .call) continue;
        const callee = arena.get(node.call.func);
        if (callee.* != .identifier) continue;
        if (std.mem.eql(u8, callee.identifier.slice(source), "print")) return @enumFromInt(i);
    }
    return null;
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

test "typecheck: print resolves through the prelude" {
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
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: print takes a String and nothing else" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print(42)
        \\    return 0
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'print' expects 'String', got 'i32'"));
}

test "typecheck: print is arity checked" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print("a", "b")
        \\    return 0
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'print' takes 1 argument(s), got 2"));
}

test "typecheck: a prelude call is void" {
    const source =
        \\fn main() -> i32 {
        \\    print("hello")
        \\    return 42
        \\}
    ;
    const allocator = std.testing.allocator;
    var arena = AstArena.init(allocator);
    defer arena.deinit();
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    defer diags.deinit();
    var parser = @import("../parser/parser.zig").Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    var type_pool = types_mod.TypePool.init(allocator);
    defer type_pool.deinit();

    var resolver = @import("resolve.zig").Resolver.init(allocator, &arena, source, &type_pool, &diags, module_node);
    defer resolver.deinit();
    try resolver.resolve();
    var checker = TypeChecker.init(allocator, &arena, source, &type_pool, &diags, &resolver.scopes, module_node);
    defer checker.deinit();
    try checker.check();

    const call = findPrintCall(&arena, source).?;
    // `print` produces no value a program can bind, so an i32 must not come
    // back from it.
    try std.testing.expect(checker.nodeType(call) == checker.voidTypeIndex());
    try std.testing.expect(!diags.hasErrors());
}

test "typecheck: generic application is accepted in type position" {
    var res = try runCheck(std.testing.allocator,
        \\struct Pair[A, B] {
        \\    first: A
        \\    second: B
        \\}
        \\struct Holder {
        \\    pair: Pair[i32, f64]
        \\}
        \\fn main() -> Pair[i32, f64] {
        \\    let p: Pair[i32, f64] = Pair[i32, f64]{ .first = 1, .second = 2.0 }
        \\    let h: Holder = Holder{ .pair = p }
        \\    return p
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

// ---------------------------------------------------------------------------
// Function values and closures (R4, R5, R7, R9, R11, R30)
// ---------------------------------------------------------------------------

/// The `n`th closure node in `arena` in arena (post-parse) order, if any. Nodes
/// are appended after their children, so a nested closure precedes the closure
/// that contains it. Node 0 is the arena's reserved sentinel and is skipped.
fn nthClosure(arena: *const AstArena, n: usize) ?NodeIdx {
    var seen: usize = 0;
    var i: usize = 1;
    while (i < arena.nodes.items.len) : (i += 1) {
        if (arena.nodes.items[i] != .closure) continue;
        if (seen == n) return @enumFromInt(i);
        seen += 1;
    }
    return null;
}

/// The name of a capture entry: the binding introduced by a `let` statement or
/// a `param`.
fn captureName(arena: *const AstArena, source: []const u8, node_idx: NodeIdx) []const u8 {
    const node = arena.get(node_idx);
    return switch (node.*) {
        .let_stmt => |l| l.name.slice(source),
        .param => |p| p.name.slice(source),
        else => "<unknown>",
    };
}

test "typecheck: fn value call through a local" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    let f = add
        \\    return f(1, 2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: fn value passed to a fn parameter" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn apply(f: fn(i32, i32) -> i32, x: i32, y: i32) -> i32 {
        \\    return f(x, y)
        \\}
        \\fn main() -> i32 {
        \\    let f = add
        \\    return apply(f, 1, 2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: fn value stored in a struct field and called" {
    var res = try runCheck(std.testing.allocator,
        \\struct Handler {
        \\    f: fn(i32) -> i32
        \\}
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1
        \\}
        \\fn main() -> i32 {
        \\    let h = Handler{ .f = inc }
        \\    return h.f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure with an annotated parameter" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = |x: i32| x + 1
        \\    return f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure infers its parameter from the body" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = |x| x + 1
        \\    return f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure infers from a let annotation" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f: fn(i32) -> i32 = |x| x + 1
        \\    return f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure infers from a parameter type at the call site" {
    var res = try runCheck(std.testing.allocator,
        \\fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
        \\    return f(x)
        \\}
        \\fn main() -> i32 {
        \\    return apply(|v| v + 1, 2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: block-bodied closure infers its return type" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = |x: i32| {
        \\        let y = x + 1
        \\        return y
        \\    }
        \\    return f(1)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure with no expected or inferred parameter type is an error" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() {
        \\    let f = |x| 42
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "cannot infer parameter type of closure parameter 'x'"));
}

test "typecheck: closure captures in source order with dedup" {
    const source =
        \\fn main() -> i32 {
        \\    let a = 1
        \\    let outer = |x: i32| {
        \\        let inner = |y: i32| x + y + a + a
        \\        return inner(3)
        \\    }
        \\    return outer(2)
        \\}
    ;
    var res = try runCheck(std.testing.allocator, source);
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());

    // The parser appends a closure node after its body, so the inner closure
    // comes first in arena order.
    const inner = nthClosure(&res.arena, 0).?;
    const outer = nthClosure(&res.arena, 1).?;

    const outer_env = res.arena.get(outer).closure.env;
    try std.testing.expectEqual(@as(usize, 1), outer_env.indices.len);
    try std.testing.expectEqualStrings("a", captureName(&res.arena, source, outer_env.indices[0]));

    // `x` is free for the inner closure; `a` used twice appears once.
    const inner_env = res.arena.get(inner).closure.env;
    try std.testing.expectEqual(@as(usize, 2), inner_env.indices.len);
    try std.testing.expectEqualStrings("x", captureName(&res.arena, source, inner_env.indices[0]));
    try std.testing.expectEqualStrings("a", captureName(&res.arena, source, inner_env.indices[1]));
}

test "typecheck: closure does not capture module fns or type names" {
    const source =
        \\struct S {
        \\    v: i32
        \\}
        \\fn helper(x: i32) -> i32 {
        \\    return x
        \\}
        \\fn main() -> i32 {
        \\    let f = |x: i32| {
        \\        let s = S{ .v = helper(x) }
        \\        return s.v
        \\    }
        \\    return f(1)
        \\}
    ;
    var res = try runCheck(std.testing.allocator, source);
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());

    const f = nthClosure(&res.arena, 0).?;
    try std.testing.expectEqual(@as(usize, 0), res.arena.get(f).closure.env.indices.len);
}

test "typecheck: closure captures an enclosing fn parameter" {
    const source =
        \\fn make(x: i32) -> i32 {
        \\    let f = |y: i32| x + y
        \\    return f(1)
        \\}
        \\fn main() -> i32 {
        \\    return make(2)
        \\}
    ;
    var res = try runCheck(std.testing.allocator, source);
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());

    const f = nthClosure(&res.arena, 0).?;
    const env = res.arena.get(f).closure.env;
    try std.testing.expectEqual(@as(usize, 1), env.indices.len);
    try std.testing.expectEqualStrings("x", captureName(&res.arena, source, env.indices[0]));
}

test "typecheck: pipeline with a hole and a bare fn value" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1
        \\}
        \\fn main() -> i32 {
        \\    let a = 1
        \\    let b = 2
        \\    let c = a |> add(_, b)
        \\    let d = c |> inc
        \\    let e = a |> add(b)
        \\    return d + e
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: pipeline into a closure" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let x = 1
        \\    let y = x |> |v| v + 1
        \\    return y
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: a hole outside a pipeline is an error" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    return add(_, 1)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'_' hole outside a pipeline"));
}
