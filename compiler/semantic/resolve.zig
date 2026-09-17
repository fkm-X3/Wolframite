const std = @import("std");
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");
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
        std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "Self");
}

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

        for (decls.indices) |decl_idx| {
            try self.collectDecl(decl_idx, module_scope);
        }

        for (decls.indices) |decl_idx| {
            try self.resolveDecl(decl_idx);
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

    fn collectDecl(self: *Resolver, decl_idx: NodeIdx, scope_idx: u32) !void {
        const decl = self.arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => |f| {
                try self.scopes.insert(self.nameSlice(f.name), .{
                    .name = f.name,
                    .kind = .function,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
            },
            .struct_decl => |s| {
                try self.scopes.insert(self.nameSlice(s.name), .{
                    .name = s.name,
                    .kind = .struct_type,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
                const struct_scope = try self.scopes.pushScope(scope_idx);
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
                for (s.methods.indices) |method_idx| {
                    try self.collectFnInScope(method_idx, struct_scope);
                }
                self.scopes.popScope();
            },
            .class_decl => |c| {
                try self.scopes.insert(self.nameSlice(c.name), .{
                    .name = c.name,
                    .kind = .class_type,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
                const class_scope = try self.scopes.pushScope(scope_idx);
                for (c.fields.indices) |field_idx| {
                    const field = self.arena.get(field_idx);
                    const field_name = self.nameSlice(field.field.name);
                    if (self.scopes.lookupCurrent(field_name) != null) {
                        self.errorAt(field_idx, "duplicate field '{s}' in class", .{field_name});
                    }
                    try self.scopes.insert(field_name, .{
                        .name = field.field.name,
                        .kind = .local,
                        .decl_node = field_idx,
                        .type_idx = TypeIdx.none,
                    });
                }
                for (c.methods.indices) |method_idx| {
                    try self.collectFnInScope(method_idx, class_scope);
                }
                self.scopes.popScope();
            },
            .enum_decl => |e| {
                try self.scopes.insert(self.nameSlice(e.name), .{
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
            .interface_decl => |i| {
                try self.scopes.insert(self.nameSlice(i.name), .{
                    .name = i.name,
                    .kind = .interface_type,
                    .decl_node = decl_idx,
                    .type_idx = TypeIdx.none,
                });
                const iface_scope = try self.scopes.pushScope(scope_idx);
                for (i.methods.indices) |method_idx| {
                    try self.collectFnInScope(method_idx, iface_scope);
                }
                self.scopes.popScope();
            },
            .impl_block => |ib| {
                _ = ib;
            },
            .import_decl => |imp| {
                const first_part = self.arena.get(imp.path.indices[0]);
                const name = self.nameSlice(first_part.identifier);
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

    fn collectFnInScope(self: *Resolver, method_idx: NodeIdx, _: u32) !void {
        const method = self.arena.get(method_idx);
        if (method.* != .fn_decl) return;
        const fn_name = self.nameSlice(method.fn_decl.name);
        if (self.scopes.lookupCurrent(fn_name) != null) {
            self.errorAt(method_idx, "duplicate method '{s}'", .{fn_name});
        }
        try self.scopes.insert(fn_name, .{
            .name = method.fn_decl.name,
            .kind = .function,
            .decl_node = method_idx,
            .type_idx = TypeIdx.none,
        });
    }

    fn resolveDecl(self: *Resolver, decl_idx: NodeIdx) anyerror!void {
        const decl = self.arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => |f| {
                try self.resolveFnDecl(decl_idx);
                _ = f;
            },
            .struct_decl => |s| {
                for (s.methods.indices) |method_idx| {
                    try self.resolveDecl(method_idx);
                }
            },
            .class_decl => |c| {
                if (c.parent) |parent| {
                    try self.resolveExpr(parent);
                }
                for (c.methods.indices) |method_idx| {
                    try self.resolveDecl(method_idx);
                }
            },
            .enum_decl => {},
            .interface_decl => {},
            .impl_block => |ib| {
                try self.resolveExpr(ib.self_type);
                const impl_scope = try self.scopes.pushScope(self.scopes.currentScope());
                for (ib.methods.indices) |method_idx| {
                    try self.collectFnInScope(method_idx, impl_scope);
                }
                for (ib.methods.indices) |method_idx| {
                    try self.resolveDecl(method_idx);
                }
                self.scopes.popScope();
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
            try self.resolveExpr(param.param.ty);
            try self.scopes.insert(param_name, .{
                .name = param.param.name,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = TypeIdx.none,
            });
        }

        if (f.return_type) |ret_ty| {
            try self.resolveExpr(ret_ty);
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
                    try self.resolveExpr(ty);
                }
                if (l.init_expr) |init_val| {
                    try self.resolveExpr(init_val);
                }
                try self.scopes.insert(self.nameSlice(l.name), .{
                    .name = l.name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = TypeIdx.none,
                });
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    try self.resolveExpr(val);
                }
            },
            .expr_stmt => |e| {
                try self.resolveExpr(e.expr);
            },
            .defer_stmt => |d| {
                try self.resolveExpr(d.expr);
            },
            .print_stmt => |p| {
                try self.resolveExpr(p.value);
            },
            .if_expr => |i| {
                try self.resolveExpr(i.cond);
                try self.resolveStmt(i.then_body);
                if (i.else_body) |else_b| {
                    try self.resolveStmt(else_b);
                }
            },
            .while_expr => |w| {
                try self.resolveExpr(w.cond);
                try self.resolveStmt(w.body);
            },
            .for_range => |fr| {
                try self.resolveExpr(fr.start);
                try self.resolveExpr(fr.end);
                _ = try self.scopes.pushScope(self.scopes.currentScope());
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
                try self.resolveExpr(fe.iterable);
                _ = try self.scopes.pushScope(self.scopes.currentScope());
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
                try self.resolveExpr(m.scrutinee);
                try self.resolveMatchArms(m);
            },
            .fn_decl => {
                try self.resolveFnDecl(stmt_idx);
            },
            else => {
                try self.resolveExpr(stmt_idx);
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
                        try self.scopes.insert(self.nameSlice(arg.identifier), .{
                            .name = arg.identifier,
                            .kind = .local,
                            .decl_node = arg_idx,
                            .type_idx = TypeIdx.none,
                        });
                    }
                }
                for (pattern.call.args.indices) |arg_idx| {
                    try self.resolveExpr(arg_idx);
                }
                try self.resolveExpr(arm.match_arm.body);
                self.scopes.popScope();
            } else {
                try self.resolveExpr(arm.match_arm.pattern);
                try self.resolveExpr(arm.match_arm.body);
            }
        }
    }

    fn resolveExpr(self: *Resolver, expr_idx: NodeIdx) anyerror!void {
        const expr = self.arena.get(expr_idx);
        switch (expr.*) {
            .identifier => |id| {
                const name = self.nameSlice(id);
                if (isBuiltinTypeName(name)) return;
                if (ast.findEnumVariant(self.arena, self.source, self.module_node, name) != null) return;
                if (self.scopes.lookup(name, self.scopes.currentScope())) |_| {
                } else {
                    self.errorAt(expr_idx, "undefined identifier '{s}'", .{name});
                }
            },
            .binary_op => |b| {
                try self.resolveExpr(b.left);
                try self.resolveExpr(b.right);
            },
            .unary_op => |u| {
                try self.resolveExpr(u.operand);
            },
            .call => |c| {
                const callee = self.arena.get(c.func);
                if (callee.* == .identifier and
                    ast.findEnumVariant(self.arena, self.source, self.module_node, self.nameSlice(callee.identifier)) != null)
                {
                    // Enum variant constructor: the name resolves inside the
                    // enum's own scope, not the current one.
                } else {
                    try self.resolveExpr(c.func);
                }
                for (c.args.indices) |arg| {
                    try self.resolveExpr(arg);
                }
            },
            .impl_type => |inner| try self.resolveExpr(inner),
            .field_access => |fa| {
                try self.resolveExpr(fa.object);
            },
            .index_access => |ia| {
                try self.resolveExpr(ia.object);
                try self.resolveExpr(ia.index);
            },
            .paren_expr => |p| {
                try self.resolveExpr(p);
            },
            .struct_init => |si| {
                try self.resolveExpr(si.ty);
                for (si.fields.indices) |field_idx| {
                    const field = self.arena.get(field_idx);
                    try self.resolveExpr(field.struct_init_field.value);
                }
            },
            .range_expr => |r| {
                try self.resolveExpr(r.start);
                try self.resolveExpr(r.end);
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
                try self.resolveExpr(i.cond);
                try self.resolveStmt(i.then_body);
                if (i.else_body) |else_b| {
                    try self.resolveStmt(else_b);
                }
            },
            .match_expr => |m| {
                try self.resolveExpr(m.scrutinee);
                try self.resolveMatchArms(m);
            },
            .param, .field, .enum_variant, .match_arm, .struct_init_field => {},
            .module, .fn_decl, .struct_decl, .class_decl, .enum_decl, .interface_decl, .impl_block, .prop_decl, .import_decl => {},
            .let_stmt, .return_stmt, .expr_stmt, .defer_stmt, .print_stmt, .while_expr, .for_range, .for_each => {},
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

test "resolve: interface declaration" {
    var res = try runResolve(std.testing.allocator,
        \\interface Speakable {
        \\    fn speak(self: *Self) -> String
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
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
        \\    let a := v.x
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

test "resolve: impl block" {
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
    try std.testing.expect(!res.diagnostics.hasErrors());
}
