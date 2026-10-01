const std = @import("std");
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");
const prelude = @import("../prelude.zig");
const scope_mod = @import("scope.zig");
const types_mod = @import("types.zig");

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const Node = ast.Node;
const NodeIdx = ast.NodeIdx;
const NodeList = ast.NodeList;
const StringRef = ast.StringRef;
const BinaryOp = ast.BinaryOp;
const UnaryOp = ast.UnaryOp;
const ScopeStack = scope_mod.ScopeStack;
const Symbol = scope_mod.Symbol;
const SymbolKind = scope_mod.SymbolKind;
const TypePool = types_mod.TypePool;
const TypeIdx = types_mod.TypeIdx;

pub fn isBuiltinTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or
        std.mem.eql(u8, name, "i32") or std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64") or
        std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "void");
}

/// The role an expression plays at its use site. Only a `fn` name in
/// `.value` position is a function value; in `.type_ref` and `.pattern`
/// position a name denotes a type or a binding and is left untouched.
const ExprPos = enum { value, type_ref, pattern };

pub const Resolver = struct {
    allocator: Allocator,
    arena: *AstArena,
    source: []const u8,
    scopes: ScopeStack,
    type_pool: *TypePool,
    diagnostics: *diag.Diagnostics,
    module_node: NodeIdx,

    pub fn init(
        allocator: Allocator,
        arena: *AstArena,
        source: []const u8,
        type_pool: *TypePool,
        diagnostics: *diag.Diagnostics,
        module_node: NodeIdx,
    ) Resolver {
        return .{
            .allocator = allocator,
            .arena = arena,
            .source = source,
            .scopes = ScopeStack.init(allocator),
            .type_pool = type_pool,
            .diagnostics = diagnostics,
            .module_node = module_node,
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.scopes.deinit();
    }

    pub fn resolve(self: *Resolver) !void {
        const mod = self.arena.get(self.module_node);
        const decls = mod.module.decls;

        const module_scope = try self.scopes.pushScope(null);

        try self.declarePrelude(module_scope);

        for (decls.indices) |decl_idx| {
            try self.collectDecl(decl_idx, module_scope);
        }

        for (decls.indices) |decl_idx| {
            try self.resolveDecl(decl_idx);
        }
    }

    /// Predeclare the prelude roster in the module root scope.
    ///
    /// This runs before `collectDecl` so a program that declares `fn print`
    /// collides with the reservation instead of silently replacing it — the
    /// roster owns the name, not the other way round.
    fn declarePrelude(self: *Resolver, scope_idx: u32) !void {
        _ = scope_idx;
        for (prelude.roster, 0..) |entry, i| {
            try self.scopes.insert(entry.name, .{
                .name = .{ .start = 0, .end = @intCast(entry.name.len) },
                .kind = .prelude_fn,
                .decl_node = NodeIdx.none,
                .type_idx = TypeIdx.none,
                .prelude = .{ .index = @intCast(i) },
            });
        }
    }

    fn nameSlice(self: *const Resolver, ref: StringRef) []const u8 {
        return ref.slice(self.source);
    }

    fn errorAt(self: *Resolver, node: NodeIdx, comptime fmt: []const u8, args: anytype) void {
        _ = node;
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch |err| {
            std.debug.panic("OOM in resolver: {s}", .{@errorName(err)});
        };
        self.diagnostics.add(.@"error", .semantic, msg, null) catch {};
    }

    /// Reject a declaration or binding that takes a prelude name.
    ///
    /// The roster owns these names: shadowing one would make the same spelling
    /// mean two things, and the direct-call lowering keys off the name
    /// (ADR-0001 §4). Reporting here rather than letting `insert` overwrite the
    /// predeclared symbol keeps the meaning of the name singular.
    fn checkPreludeCollision(self: *Resolver, node: NodeIdx, name: []const u8) bool {
        if (!prelude.isReserved(name)) return false;
        self.errorAt(node, "cannot redefine prelude function '{s}'", .{name});
        return true;
    }

    fn collectDecl(self: *Resolver, decl_idx: NodeIdx, scope_idx: u32) !void {
        const decl = self.arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => |f| {
                const name = self.nameSlice(f.name);
                if (self.checkPreludeCollision(decl_idx, name)) return;
                try self.scopes.insert(name, .{
                    .name = f.name,
                    .kind = .function,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
            },
            .struct_decl => |s| {
                const struct_name = self.nameSlice(s.name);
                if (self.checkPreludeCollision(decl_idx, struct_name)) return;
                try self.scopes.insert(struct_name, .{
                    .name = s.name,
                    .kind = .struct_type,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
                _ = try self.scopes.pushScope(scope_idx);
                for (s.fields.indices) |field_idx| {
                    const field = self.arena.get(field_idx);
                    const field_name = self.nameSlice(field.field.name);
                    if (self.scopes.lookupCurrent(field_name) != null) {
                        self.errorAt(field_idx, "duplicate field '{s}' in struct", .{field_name});
                    }
                    try self.scopes.insert(field_name, .{
                        .name = field.field.name,
                        .kind = .local,
                        .decl_node = field_idx,
                        .type_idx = TypeIdx.none,
                    });
                }
                self.scopes.popScope();
            },
            .enum_decl => |e| {
                const enum_name = self.nameSlice(e.name);
                if (self.checkPreludeCollision(decl_idx, enum_name)) return;
                try self.scopes.insert(enum_name, .{
                    .name = e.name,
                    .kind = .enum_type,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
                _ = try self.scopes.pushScope(scope_idx);
                for (e.variants.indices) |variant_idx| {
                    const variant = self.arena.get(variant_idx);
                    const variant_name = self.nameSlice(variant.enum_variant.name);
                    if (self.scopes.lookupCurrent(variant_name) != null) {
                        self.errorAt(variant_idx, "duplicate variant '{s}' in enum", .{variant_name});
                    }
                    try self.scopes.insert(variant_name, .{
                        .name = variant.enum_variant.name,
                        .kind = .local,
                        .decl_node = variant_idx,
                        .type_idx = TypeIdx.none,
                    });
                }
                self.scopes.popScope();
            },
            .import_decl => |imp| {
                const first_part = self.arena.get(imp.path.indices[0]);
                const name = self.nameSlice(first_part.identifier);
                if (self.checkPreludeCollision(decl_idx, name)) return;
                try self.scopes.insert(name, .{
                    .name = first_part.identifier,
                    .kind = .module,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
            },
            else => {},
        }
    }

    fn resolveDecl(self: *Resolver, decl_idx: NodeIdx) anyerror!void {
        const decl = self.arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => {
                try self.resolveFnDecl(decl_idx);
            },
            else => {},
        }
    }

    fn resolveFnDecl(self: *Resolver, fn_idx: NodeIdx) anyerror!void {
        const fn_decl = self.arena.get(fn_idx);
        const f = fn_decl.fn_decl;
        _ = try self.scopes.pushScope(self.scopes.currentScope());

        for (f.generic_params.indices) |gp_idx| {
            const gp = self.arena.get(gp_idx);
            const gp_name = self.nameSlice(gp.identifier);
            if (self.checkPreludeCollision(gp_idx, gp_name)) continue;
            try self.scopes.insert(gp_name, .{
                .name = gp.identifier,
                .kind = .generic_param,
                .decl_node = gp_idx,
                .type_idx = TypeIdx.none,
            });
        }

        for (f.params.indices) |param_idx| {
            const param = self.arena.get(param_idx);
            const param_name = self.nameSlice(param.param.name);
            if (self.scopes.lookupCurrent(param_name) != null) {
                self.errorAt(param_idx, "duplicate parameter '{s}'", .{param_name});
            }
            if (self.checkPreludeCollision(param_idx, param_name)) continue;
            try self.resolveTypeRef(param.param.ty);
            try self.scopes.insert(param_name, .{
                .name = param.param.name,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = TypeIdx.none,
            });
        }

        if (f.return_type) |ret_ty| {
            try self.resolveTypeRef(ret_ty);
        }

        if (f.body != NodeIdx.none) {
            try self.resolveStmt(f.body);
        }

        self.scopes.popScope();
    }

    fn resolveStmt(self: *Resolver, stmt_idx: NodeIdx) anyerror!void {
        const stmt = self.arena.get(stmt_idx);
        switch (stmt.*) {
            .block => |b| {
                _ = try self.scopes.pushScope(self.scopes.currentScope());
                for (b.stmts.indices) |inner| {
                    try self.resolveStmt(inner);
                }
                self.scopes.popScope();
            },
            .let_stmt => |l| {
                if (l.ty) |ty| {
                    try self.resolveTypeRef(ty);
                }
                if (l.init_expr) |init_val| {
                    try self.resolveValue(init_val);
                }
                const local_name = self.nameSlice(l.name);
                if (self.checkPreludeCollision(stmt_idx, local_name)) return;
                try self.scopes.insert(local_name, .{
                    .name = l.name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = TypeIdx.none,
                });
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    try self.resolveValue(val);
                }
            },
            .expr_stmt => |e| {
                try self.resolveValue(e.expr);
            },
            .defer_stmt => |d| {
                try self.resolveValue(d.expr);
            },
            .if_expr => |i| {
                try self.resolveValue(i.cond);
                try self.resolveStmt(i.then_body);
                if (i.else_body) |else_b| {
                    try self.resolveStmt(else_b);
                }
            },
            .while_expr => |w| {
                try self.resolveValue(w.cond);
                try self.resolveStmt(w.body);
            },
            .for_range => |fr| {
                try self.resolveValue(fr.start);
                try self.resolveValue(fr.end);
                _ = try self.scopes.pushScope(self.scopes.currentScope());
                if (self.checkPreludeCollision(stmt_idx, self.nameSlice(fr.var_name))) {
                    self.scopes.popScope();
                    return;
                }
                try self.scopes.insert(self.nameSlice(fr.var_name), .{
                    .name = fr.var_name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = TypeIdx.none,
                });
                try self.resolveStmt(fr.body);
                self.scopes.popScope();
            },
            .for_each => |fe| {
                try self.resolveValue(fe.iterable);
                _ = try self.scopes.pushScope(self.scopes.currentScope());
                if (self.checkPreludeCollision(stmt_idx, self.nameSlice(fe.var_name))) {
                    self.scopes.popScope();
                    return;
                }
                try self.scopes.insert(self.nameSlice(fe.var_name), .{
                    .name = fe.var_name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = TypeIdx.none,
                });
                try self.resolveStmt(fe.body);
                self.scopes.popScope();
            },
            .match_expr => |m| {
                try self.resolveValue(m.scrutinee);
                try self.resolveMatchArms(m);
            },
            .fn_decl => {
                try self.resolveFnDecl(stmt_idx);
            },
            else => {
                try self.resolveValue(stmt_idx);
            },
        }
    }

    /// Resolve each match arm. When the pattern is an enum variant call
    /// (`Some(x)`), the payload identifiers are bound in a scope that covers
    /// the arm body only.
    fn resolveMatchArms(self: *Resolver, m: anytype) anyerror!void {
        for (m.arms.indices) |arm_idx| {
            const arm = self.arena.get(arm_idx);
            const pattern = self.arena.get(arm.match_arm.pattern);
            var variant_info: ?ast.EnumVariantInfo = null;
            if (pattern.* == .call) {
                const callee = self.arena.get(pattern.call.func);
                if (callee.* == .identifier) {
                    variant_info = ast.findEnumVariant(self.arena, self.source, self.module_node, self.nameSlice(callee.identifier));
                }
            }
            if (variant_info) |vi| {
                _ = try self.scopes.pushScope(self.scopes.currentScope());
                const variant = self.arena.get(vi.variant_node);
                for (pattern.call.args.indices, 0..) |arg_idx, i| {
                    const arg = self.arena.get(arg_idx);
                    if (i < variant.enum_variant.fields.indices.len and arg.* == .identifier) {
                        if (self.checkPreludeCollision(arg_idx, self.nameSlice(arg.identifier))) continue;
                        try self.scopes.insert(self.nameSlice(arg.identifier), .{
                            .name = arg.identifier,
                            .kind = .local,
                            .decl_node = arg_idx,
                            .type_idx = TypeIdx.none,
                        });
                    }
                }
                for (pattern.call.args.indices) |arg_idx| {
                    try self.resolveAt(.value, arg_idx);
                }
                if (arm.match_arm.guard) |guard| {
                    try self.resolveAt(.value, guard);
                }
                try self.resolveAt(.value, arm.match_arm.body);
                self.scopes.popScope();
            } else {
                try self.resolveAt(.pattern, arm.match_arm.pattern);
                if (arm.match_arm.guard) |guard| {
                    try self.resolveAt(.value, guard);
                }
                try self.resolveAt(.value, arm.match_arm.body);
            }
        }
    }

    /// Resolve a name: report it when it is not visible anywhere up the scope
    /// stack, otherwise return the symbol it denotes.
    fn resolveName(self: *Resolver, expr_idx: NodeIdx) ?Symbol {
        const id = self.arena.get(expr_idx).identifier;
        const name = self.nameSlice(id);
        if (std.mem.eql(u8, name, "_")) return null;
        if (isBuiltinTypeName(name)) return null;
        if (ast.findEnumVariant(self.arena, self.source, self.module_node, name) != null) return null;
        return self.scopes.lookup(name, self.scopes.currentScope()) orelse {
            self.errorAt(expr_idx, "undefined identifier '{s}'", .{name});
            return null;
        };
    }

    /// A `fn` name used as a value is a first-class function. Rewrite the
    /// identifier into an `fn_ref` so downstream passes read the reference
    /// instead of re-deriving it from the name. `main` and uninstantiated
    /// generic `fn`s are not function values and are left as plain names.
    fn bindFnValue(self: *Resolver, expr_idx: NodeIdx, sym: Symbol) void {
        const name = self.nameSlice(sym.name);
        const f = self.arena.get(sym.decl_node).fn_decl;
        if (f.generic_params.indices.len > 0) {
            self.errorAt(expr_idx, "generic fn '{s}' requires type arguments to be used as a value", .{name});
            return;
        }
        if (std.mem.eql(u8, name, "main")) {
            self.errorAt(expr_idx, "'main' cannot be used as a value", .{});
            return;
        }
        self.arena.set(expr_idx, .{ .fn_ref = sym.name });
    }

    /// A bare name in head position names the entity being applied or indexed,
    /// not a function value: `add(1, 2)`, `fns[0]` and `first[[i32]]` all keep
    /// the name. Anything else in head position (a field or element holding a
    /// function) is an ordinary value.
    fn resolveHead(self: *Resolver, expr_idx: NodeIdx) anyerror!void {
        if (self.arena.get(expr_idx).* == .identifier) {
            _ = self.resolveName(expr_idx);
            return;
        }
        try self.resolveAt(.value, expr_idx);
    }

    fn resolveValue(self: *Resolver, expr_idx: NodeIdx) anyerror!void {
        return self.resolveAt(.value, expr_idx);
    }

    fn resolveTypeRef(self: *Resolver, expr_idx: NodeIdx) anyerror!void {
        return self.resolveAt(.type_ref, expr_idx);
    }

    fn resolveAt(self: *Resolver, pos: ExprPos, expr_idx: NodeIdx) anyerror!void {
        const expr = self.arena.get(expr_idx);
        switch (expr.*) {
            .identifier => {
                const sym = self.resolveName(expr_idx) orelse return;
                if (pos != .value) return;
                switch (sym.kind) {
                    .function => self.bindFnValue(expr_idx, sym),
                    // A prelude entry is not a Wolframite `fn` value: it has no
                    // body and no type to instantiate, so taking it as a value
                    // cannot mean anything yet.
                    .prelude_fn => self.errorAt(expr_idx, "prelude function '{s}' cannot be used as a value", .{
                        sym.displayName(self.source),
                    }),
                    else => {},
                }
            },
            .binary_op => |b| {
                try self.resolveAt(.value, b.left);
                try self.resolveAt(.value, b.right);
            },
            .unary_op => |u| {
                try self.resolveAt(.value, u.operand);
            },
            .call => |c| {
                const callee = self.arena.get(c.func);
                if (callee.* == .identifier and
                    ast.findEnumVariant(self.arena, self.source, self.module_node, self.nameSlice(callee.identifier)) != null)
                {
                    // Enum variant constructor: the name resolves inside the
                    // enum's own scope, not the current one.
                } else {
                    // A direct call names the function; it is not a fn value.
                    try self.resolveHead(c.func);
                }
                for (c.args.indices) |arg| {
                    try self.resolveAt(.value, arg);
                }
            },
            .fn_type => |ft| {
                for (ft.params.indices) |param_ty| {
                    try self.resolveTypeRef(param_ty);
                }
                try self.resolveTypeRef(ft.return_type);
            },
            .fn_ref => |id| {
                const name = self.nameSlice(id);
                const sym = self.scopes.lookup(name, self.scopes.currentScope());
                if (sym == null or sym.?.kind != .function) {
                    self.errorAt(expr_idx, "'{s}' is not a function", .{name});
                }
            },
            .closure => |cl| {
                _ = try self.scopes.pushScope(self.scopes.currentScope());
                for (cl.params.indices) |param_idx| {
                    const param = self.arena.get(param_idx);
                    if (self.checkPreludeCollision(param_idx, self.nameSlice(param.param.name))) continue;
                    if (param.param.ty != NodeIdx.none) {
                        try self.resolveTypeRef(param.param.ty);
                    }
                    try self.scopes.insert(self.nameSlice(param.param.name), .{
                        .name = param.param.name,
                        .kind = .param,
                        .decl_node = param_idx,
                        .type_idx = TypeIdx.none,
                    });
                }
                try self.resolveAt(.value, cl.body);
                self.scopes.popScope();
            },
            .comptime_block => |inner| try self.resolveStmt(inner),
            .comptime_expr => |inner| try self.resolveAt(.value, inner),
            .comptime_call => |cc| {
                for (cc.args.indices) |arg| {
                    try self.resolveAt(.value, arg);
                }
            },
            .pipeline => |p| {
                try self.resolveAt(.value, p.lhs);
                try self.resolveAt(.value, p.rhs);
            },
            .try_propagate => |inner| try self.resolveAt(.value, inner),
            .move_expr => |inner| try self.resolveAt(.value, inner),
            .region_expr => |r| {
                if (r.allocator) |alloc_ty| {
                    try self.resolveTypeRef(alloc_ty);
                }
                _ = try self.scopes.pushScope(self.scopes.currentScope());
                try self.resolveStmt(r.body);
                self.scopes.popScope();
            },
            .field_access => |fa| {
                try self.resolveAt(.value, fa.object);
            },
            .index_access => |ia| {
                try self.resolveHead(ia.object);
                try self.resolveAt(.value, ia.index);
            },
            .generic_app => |ga| {
                try self.resolveHead(ga.base);
                for (ga.args.indices) |arg| {
                    try self.resolveTypeRef(arg);
                }
            },
            .paren_expr => |p| {
                try self.resolveAt(pos, p);
            },
            .struct_init => |si| {
                try self.resolveTypeRef(si.ty);
                for (si.fields.indices) |field_idx| {
                    const field = self.arena.get(field_idx);
                    try self.resolveAt(.value, field.struct_init_field.value);
                }
            },
            .range_expr => |r| {
                try self.resolveAt(.value, r.start);
                try self.resolveAt(.value, r.end);
            },
            .int_literal, .float_literal, .string_literal, .char_literal, .bool_literal, .null_literal => {},
            .block => |b| {
                _ = try self.scopes.pushScope(self.scopes.currentScope());
                for (b.stmts.indices) |stmt| {
                    try self.resolveStmt(stmt);
                }
                self.scopes.popScope();
            },
            .if_expr => |i| {
                try self.resolveAt(.value, i.cond);
                try self.resolveStmt(i.then_body);
                if (i.else_body) |else_b| {
                    try self.resolveStmt(else_b);
                }
            },
            .match_expr => |m| {
                try self.resolveAt(.value, m.scrutinee);
                try self.resolveMatchArms(m);
            },
            .param, .field, .enum_variant, .match_arm, .struct_init_field => {},
            .module, .fn_decl, .struct_decl, .enum_decl, .import_decl => {},
            .let_stmt, .return_stmt, .expr_stmt, .defer_stmt, .while_expr, .for_range, .for_each => {},
        }
    }
};

fn runResolve(allocator: Allocator, source: []const u8) !struct { arena: AstArena, type_pool: TypePool, diagnostics: diag.Diagnostics } {
    var arena = AstArena.init(allocator);
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    var parser = @import("../parser/parser.zig").Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    var type_pool = TypePool.init(allocator);
    {
        var resolver = Resolver.init(allocator, &arena, source, &type_pool, &diags, module_node);
        defer resolver.deinit();
        try resolver.resolve();
    }
    return .{ .arena = arena, .type_pool = type_pool, .diagnostics = diags };
}

/// Number of `fn_ref` nodes the resolver produced.
fn countFnRefs(arena: *const AstArena) usize {
    var count: usize = 0;
    for (arena.nodes.items) |node| {
        if (std.meta.activeTag(node) == .fn_ref) count += 1;
    }
    return count;
}

fn firstFnRefName(arena: *const AstArena, source: []const u8) ?[]const u8 {
    for (arena.nodes.items) |node| {
        if (std.meta.activeTag(node) == .fn_ref) return node.fn_ref.slice(source);
    }
    return null;
}

fn hasMessage(diagnostics: *const diag.Diagnostics, needle: []const u8) bool {
    for (diagnostics.items.items) |item| {
        if (std.mem.indexOf(u8, item.message, needle) != null) return true;
    }
    return false;
}

test "resolve: empty module" {
    var res = try runResolve(std.testing.allocator, "");
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "resolve: function declaration" {
    var res = try runResolve(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "resolve: struct declaration" {
    var res = try runResolve(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "resolve: enum declaration" {
    var res = try runResolve(std.testing.allocator,
        \\enum Option[T] {
        \\    Some(T)
        \\    None
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "resolve: interface declaration no longer parses" {
    var res = try runResolve(std.testing.allocator,
        \\interface Speakable {
        \\    fn speak(self: &Self) -> String
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
}

test "resolve: variable references and scoping" {
    var res = try runResolve(std.testing.allocator,
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

test "resolve: undefined identifier error" {
    var res = try runResolve(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return undefined_var
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
}

test "resolve: nested scope" {
    var res = try runResolve(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let x: i32 = 1
        \\    {
        \\        let y: i32 = x
        \\    }
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

test "resolve: function call" {
    var res = try runResolve(std.testing.allocator,
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

test "resolve: if expression" {
    var res = try runResolve(std.testing.allocator,
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

test "resolve: for range loop" {
    var res = try runResolve(std.testing.allocator,
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

test "resolve: match expression" {
    var res = try runResolve(std.testing.allocator,
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

test "resolve: field access" {
    var res = try runResolve(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn main() {
        \\    let v: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
        \\    let a = v.x
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "resolve: import declaration" {
    var res = try runResolve(std.testing.allocator, "import math");
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "resolve: impl block no longer parses" {
    var res = try runResolve(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\impl Vec2 {
        \\    fn zero() -> Vec2 {
        \\        return Vec2{ .x = 0.0, .y = 0.0 }
        \\    }
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
}

test "resolve: Self is not a builtin type name" {
    var res = try runResolve(std.testing.allocator,
        \\fn identity(x: Self) -> Self {
        \\    return x
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "undefined identifier 'Self'"));
}

test "resolve: fn name in value position becomes an fn_ref" {
    const source =
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
    ;
    var res = try runResolve(std.testing.allocator, source);
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), countFnRefs(&res.arena));
    try std.testing.expectEqualStrings("add", firstFnRefName(&res.arena, source).?);
}

test "resolve: a direct call keeps the callee a plain name" {
    var res = try runResolve(std.testing.allocator,
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
    try std.testing.expectEqual(@as(usize, 0), countFnRefs(&res.arena));
}

test "resolve: fn value in a pipeline, an argument, and a field" {
    const source =
        \\struct Handler {
        \\    f: fn(i32) -> i32
        \\}
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1
        \\}
        \\fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
        \\    return f(x)
        \\}
        \\fn main() -> i32 {
        \\    let h = Handler{ .f = inc }
        \\    let y = 1 |> inc
        \\    return apply(inc, y) + h.f(2)
        \\}
    ;
    var res = try runResolve(std.testing.allocator, source);
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
    try std.testing.expectEqual(@as(usize, 3), countFnRefs(&res.arena));
    try std.testing.expectEqualStrings("inc", firstFnRefName(&res.arena, source).?);
}

test "resolve: a local shadows a module fn of the same name" {
    var res = try runResolve(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    let add = 1
        \\    return add
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), countFnRefs(&res.arena));
}

test "resolve: an uninstantiated generic fn is not a value" {
    var res = try runResolve(std.testing.allocator,
        \\fn first[T](list: T) -> T {
        \\    return list
        \\}
        \\fn main() -> i32 {
        \\    let f = first
        \\    return 0
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "generic fn 'first' requires type arguments"));
    try std.testing.expectEqual(@as(usize, 0), countFnRefs(&res.arena));
}

test "resolve: main is not a value" {
    var res = try runResolve(std.testing.allocator,
        \\fn helper() -> i32 {
        \\    return 1
        \\}
        \\fn main() -> i32 {
        \\    let f = main
        \\    return helper()
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'main' cannot be used as a value"));
    try std.testing.expectEqual(@as(usize, 0), countFnRefs(&res.arena));
}

test "resolve: print resolves without a declaration" {
    var res = try runResolve(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print("Hello, world!")
        \\    return 42
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
    // A direct call keeps the callee a plain name; the lowerer resolves it.
    try std.testing.expectEqual(@as(usize, 0), countFnRefs(&res.arena));
}

test "resolve: a program cannot redefine a prelude function" {
    var res = try runResolve(std.testing.allocator,
        \\fn print(s: String) {
        \\    return
        \\}
        \\fn main() -> i32 {
        \\    return 0
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "cannot redefine prelude function 'print'"));
}

test "resolve: a local cannot shadow a prelude function" {
    var res = try runResolve(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let print = 1
        \\    return print
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "cannot redefine prelude function 'print'"));
}

test "resolve: a prelude name cannot be bound by any declaration kind" {
    // Every binder the resolver knows about has to route through the same check,
    // otherwise a program could smuggle a local `print` in through the one
    // construct that forgot.
    const sources = [_][]const u8{
        \\struct print { }
        \\fn main() -> i32 { return 0 }
        ,
        \\enum print { A }
        \\fn main() -> i32 { return 0 }
        ,
        \\import print
        \\fn main() -> i32 { return 0 }
        ,
        \\fn print(s: String) { }
        \\fn main() -> i32 { return 0 }
        ,
        \\fn main(print: i32) -> i32 { return print }
        ,
        \\fn main[T](print: T) -> i32 { return 0 }
        ,
        \\fn main() -> i32 {
        \\    for print in 0..3 { return print }
        \\    return 0
        \\}
        ,
        \\fn main() -> i32 {
        \\    let items = "abc"
        \\    for print in items { return 1 }
        \\    return 0
        \\}
        ,
        \\fn main() -> i32 {
        \\    let f = |print: i32| print
        \\    return 0
        \\}
        ,
    };
    for (sources) |src| {
        var res = try runResolve(std.testing.allocator, src);
        defer {
            res.arena.deinit();
            res.type_pool.deinit();
            res.diagnostics.deinit();
        }
        try std.testing.expect(res.diagnostics.hasErrors());
        try std.testing.expect(hasMessage(&res.diagnostics, "cannot redefine prelude function 'print'"));
    }
}

test "resolve: a prelude function cannot be used as a value" {
    var res = try runResolve(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = print
        \\    return 0
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "prelude function 'print' cannot be used as a value"));
}

test "resolve: resolve: a fn type annotation is not a fn value" {
    var res = try runResolve(std.testing.allocator,
        \\fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
        \\    return f(x)
        \\}
        \\fn main() -> i32 {
        \\    let g: fn(i32) -> i32 = inc
        \\    return g(1)
        \\}
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), countFnRefs(&res.arena));
}
