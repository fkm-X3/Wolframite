const std = @import("std");

pub const StringRef = struct {
    start: u32,
    end: u32,

    pub fn slice(self: StringRef, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const NodeIdx = enum(u32) {
    none = 0,
    _,

    pub fn toInt(self: NodeIdx) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(v: u32) NodeIdx {
        return @enumFromInt(v);
    }
};

pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    and_op,
    or_op,
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    range,
};

pub const UnaryOp = enum(u8) {
    neg,
    not,
    bit_not,
    ref,
    mut_ref,
};

pub const NodeList = struct {
    indices: []const NodeIdx,
};

pub const Node = union(enum) {
    // Literals / primaries
    int_literal: i64,
    float_literal: f64,
    string_literal: StringRef,
    char_literal: StringRef,
    bool_literal: bool,
    null_literal,
    identifier: StringRef,

    // Expressions
    binary_op: struct { op: BinaryOp, left: NodeIdx, right: NodeIdx },
    unary_op: struct { op: UnaryOp, operand: NodeIdx },
    call: struct { func: NodeIdx, args: NodeList },
    field_access: struct { object: NodeIdx, field: StringRef },
    index_access: struct { object: NodeIdx, index: NodeIdx },
    /// `Name[A, B]` — a generic application. A single-argument application
    /// (`Option[i32]`) stays an `index_access`; the semantic passes read a type
    /// name on the left of one as a generic application. `args` holds one type
    /// node per argument, in written order.
    generic_app: struct { base: NodeIdx, args: NodeList },
    paren_expr: NodeIdx,
    struct_init: struct { ty: NodeIdx, fields: NodeList },
    range_expr: struct { start: NodeIdx, end: NodeIdx },
    /// `fn(A, B) -> R`. Legal in type position (a first-class fn type) and in
    /// expression position (a comptime type value, not a runtime function).
    /// `params` holds one type node per parameter, in declaration order.
    fn_type: struct { params: NodeList, return_type: NodeIdx },
    /// A named function used as a value (`apply(add, 2, 3)`). The parser emits
    /// a plain `identifier`; the resolver rewrites it here once the name is
    /// known to denote a `fn`.
    fn_ref: StringRef,
    /// Closure literal `|x, y| expr` or `|x| { ... }`. `env` is populated by
    /// the semantic passes (captured bindings); the parser leaves it empty.
    closure: struct { params: NodeList, body: NodeIdx, env: NodeList },
    /// `comptime { ... }` — `body` is a block node.
    comptime_block: NodeIdx,
    /// `comptime expr`.
    comptime_expr: NodeIdx,
    /// `lhs |> rhs` pipeline.
    pipeline: struct { lhs: NodeIdx, rhs: NodeIdx },
    /// Postfix `?` error propagation on `operand`.
    try_propagate: NodeIdx,
    /// `region name (: allocator_type)? { stmt* }` arena scope.
    region_expr: struct { name: StringRef, allocator: ?NodeIdx, body: NodeIdx },
    /// `move expr` explicit move into a binding.
    move_expr: NodeIdx,
    /// `@name(args)` comptime builtin call.
    comptime_call: struct { name: StringRef, args: NodeList },

    // Statements
    let_stmt: struct { mutable: bool, name: StringRef, ty: ?NodeIdx, init_expr: ?NodeIdx },
    return_stmt: struct { value: ?NodeIdx },
    expr_stmt: struct { expr: NodeIdx },
    defer_stmt: struct { expr: NodeIdx },

    // Declarations
    fn_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        params: NodeList,
        return_type: ?NodeIdx,
        body: NodeIdx,
    },
    struct_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        fields: NodeList,
    },
    enum_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        variants: NodeList,
    },
    import_decl: struct { path: NodeList, alias: ?StringRef },

    // Control flow
    if_expr: struct { cond: NodeIdx, then_body: NodeIdx, else_body: ?NodeIdx },
    while_expr: struct { cond: NodeIdx, body: NodeIdx },
    for_range: struct { var_name: StringRef, start: NodeIdx, end: NodeIdx, body: NodeIdx },
    for_each: struct { var_name: StringRef, iterable: NodeIdx, body: NodeIdx },
    match_expr: struct { scrutinee: NodeIdx, arms: NodeList },
    block: struct { stmts: NodeList },

    // Module root
    module: struct { decls: NodeList },

    // Misc
    param: struct { name: StringRef, ty: NodeIdx },
    field: struct { name: StringRef, ty: TypeRepr },
    enum_variant: struct { name: StringRef, fields: NodeList },
    /// `pattern (if guard)? => body`. `guard` is an optional boolean expr.
    match_arm: struct { pattern: NodeIdx, guard: ?NodeIdx, body: NodeIdx },
    struct_init_field: struct { name: StringRef, value: NodeIdx },
};

pub const TypeRepr = union(enum) {
    /// A type expression node: a name, a `generic_app`, an `fn_type`, ...
    plain: NodeIdx,
    /// `&T` shared reference.
    reference: NodeIdx,
    /// `&mut T` exclusive reference.
    mut_reference: NodeIdx,
};

pub const AstArena = struct {
    nodes: std.ArrayListUnmanaged(Node),
    allocator: std.mem.Allocator,
    list_allocs: std.ArrayListUnmanaged([]NodeIdx),

    pub fn init(allocator: std.mem.Allocator) AstArena {
        var arena = AstArena{
            .nodes = .empty,
            .allocator = allocator,
            .list_allocs = .empty,
        };
        arena.nodes.append(allocator, undefined) catch unreachable;
        return arena;
    }

    pub fn deinit(self: *AstArena) void {
        for (self.list_allocs.items) |slice| {
            self.allocator.free(slice);
        }
        self.list_allocs.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    pub fn append(self: *AstArena, node: Node) !NodeIdx {
        const idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, node);
        return NodeIdx.fromInt(@intCast(idx));
    }

    pub fn get(self: *const AstArena, idx: NodeIdx) *const Node {
        return &self.nodes.items[@as(usize, @intCast(idx.toInt()))];
    }

    /// Overwrite an existing node in place. The semantic passes use this to
    /// rewrite a node once the name it holds is known to denote a different
    /// entity (e.g. an `identifier` that names a `fn` becomes an `fn_ref`).
    pub fn set(self: *AstArena, idx: NodeIdx, node: Node) void {
        self.nodes.items[@as(usize, @intCast(idx.toInt()))] = node;
    }

    pub fn allocNodeList(self: *AstArena, indices: []const NodeIdx) !NodeList {
        const copy = try self.allocator.alloc(NodeIdx, indices.len);
        @memcpy(copy, indices);
        try self.list_allocs.append(self.allocator, copy);
        return .{ .indices = copy };
    }
};

/// Deep-clone the AST subtree rooted at `root` into the same arena.
///
/// The clone gets fresh node indices and every reference inside it — child
/// nodes, node lists, and a closure's capture list — is remapped to the
/// clone, so the copy is a self-contained tree. Monomorphization uses this to
/// give every instance of a generic declaration its own copy of the body,
/// which is then resolved and type-checked on its own (docs/semantics.md
/// §7.3, step 2).
pub fn cloneSubtree(arena: *AstArena, root: NodeIdx) std.mem.Allocator.Error!NodeIdx {
    var map: std.AutoHashMapUnmanaged(NodeIdx, NodeIdx) = .empty;
    defer map.deinit(arena.allocator);
    return cloneNode(arena, root, &map);
}

/// Clone one node and its children, memoizing the mapping from the original
/// index to the clone. A node reachable twice (a closure's capture list points
/// back at a binding in the enclosing body) is cloned once.
fn cloneNode(
    arena: *AstArena,
    idx: NodeIdx,
    map: *std.AutoHashMapUnmanaged(NodeIdx, NodeIdx),
) std.mem.Allocator.Error!NodeIdx {
    if (map.get(idx)) |existing| return existing;
    const node = arena.get(idx);

    switch (node.*) {
        .int_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .identifier,
        .fn_ref,
        => {
            return appendClone(arena, idx, map, node.*);
        },
        .binary_op => |b| {
            const left = try cloneNode(arena, b.left, map);
            const right = try cloneNode(arena, b.right, map);
            return appendClone(arena, idx, map, .{ .binary_op = .{ .op = b.op, .left = left, .right = right } });
        },
        .unary_op => |u| {
            const operand = try cloneNode(arena, u.operand, map);
            return appendClone(arena, idx, map, .{ .unary_op = .{ .op = u.op, .operand = operand } });
        },
        .call => |c| {
            const func = try cloneNode(arena, c.func, map);
            const args = try cloneList(arena, c.args, map);
            return appendClone(arena, idx, map, .{ .call = .{ .func = func, .args = args } });
        },
        .field_access => |fa| {
            const object = try cloneNode(arena, fa.object, map);
            return appendClone(arena, idx, map, .{ .field_access = .{ .object = object, .field = fa.field } });
        },
        .index_access => |ia| {
            const object = try cloneNode(arena, ia.object, map);
            const index = try cloneNode(arena, ia.index, map);
            return appendClone(arena, idx, map, .{ .index_access = .{ .object = object, .index = index } });
        },
        .generic_app => |ga| {
            const base = try cloneNode(arena, ga.base, map);
            const args = try cloneList(arena, ga.args, map);
            return appendClone(arena, idx, map, .{ .generic_app = .{ .base = base, .args = args } });
        },
        .paren_expr => |p| {
            const inner = try cloneNode(arena, p, map);
            return appendClone(arena, idx, map, .{ .paren_expr = inner });
        },
        .struct_init => |si| {
            const ty = try cloneNode(arena, si.ty, map);
            const fields = try cloneList(arena, si.fields, map);
            return appendClone(arena, idx, map, .{ .struct_init = .{ .ty = ty, .fields = fields } });
        },
        .range_expr => |r| {
            const start = try cloneNode(arena, r.start, map);
            const end = try cloneNode(arena, r.end, map);
            return appendClone(arena, idx, map, .{ .range_expr = .{ .start = start, .end = end } });
        },
        .fn_type => |ft| {
            const params = try cloneList(arena, ft.params, map);
            const return_type = try cloneNode(arena, ft.return_type, map);
            return appendClone(arena, idx, map, .{ .fn_type = .{ .params = params, .return_type = return_type } });
        },
        .closure => |cl| {
            const params = try cloneList(arena, cl.params, map);
            const body = try cloneNode(arena, cl.body, map);
            // The capture list points back at bindings in the enclosing body,
            // so it is cloned with the closure; the memoized clone keeps the
            // two references on the same node.
            const env = try cloneList(arena, cl.env, map);
            return appendClone(arena, idx, map, .{ .closure = .{ .params = params, .body = body, .env = env } });
        },
        .comptime_block => |inner| {
            const body = try cloneNode(arena, inner, map);
            return appendClone(arena, idx, map, .{ .comptime_block = body });
        },
        .comptime_expr => |inner| {
            const body = try cloneNode(arena, inner, map);
            return appendClone(arena, idx, map, .{ .comptime_expr = body });
        },
        .comptime_call => |cc| {
            const args = try cloneList(arena, cc.args, map);
            return appendClone(arena, idx, map, .{ .comptime_call = .{ .name = cc.name, .args = args } });
        },
        .pipeline => |p| {
            const lhs = try cloneNode(arena, p.lhs, map);
            const rhs = try cloneNode(arena, p.rhs, map);
            return appendClone(arena, idx, map, .{ .pipeline = .{ .lhs = lhs, .rhs = rhs } });
        },
        .try_propagate => |inner| {
            const operand = try cloneNode(arena, inner, map);
            return appendClone(arena, idx, map, .{ .try_propagate = operand });
        },
        .region_expr => |r| {
            const allocator = if (r.allocator) |a| try cloneNode(arena, a, map) else NodeIdx.none;
            const body = try cloneNode(arena, r.body, map);
            return appendClone(arena, idx, map, .{ .region_expr = .{ .name = r.name, .allocator = allocator, .body = body } });
        },
        .move_expr => |inner| {
            const operand = try cloneNode(arena, inner, map);
            return appendClone(arena, idx, map, .{ .move_expr = operand });
        },
        .let_stmt => |l| {
            const ty = if (l.ty) |t| try cloneNode(arena, t, map) else null;
            const init_expr = if (l.init_expr) |e| try cloneNode(arena, e, map) else null;
            return appendClone(arena, idx, map, .{ .let_stmt = .{
                .mutable = l.mutable,
                .name = l.name,
                .ty = ty,
                .init_expr = init_expr,
            } });
        },
        .return_stmt => |r| {
            const value = if (r.value) |v| try cloneNode(arena, v, map) else null;
            return appendClone(arena, idx, map, .{ .return_stmt = .{ .value = value } });
        },
        .expr_stmt => |e| {
            const expr = try cloneNode(arena, e.expr, map);
            return appendClone(arena, idx, map, .{ .expr_stmt = .{ .expr = expr } });
        },
        .defer_stmt => |d| {
            const expr = try cloneNode(arena, d.expr, map);
            return appendClone(arena, idx, map, .{ .defer_stmt = .{ .expr = expr } });
        },
        .fn_decl => |f| {
            const generic_params = try cloneList(arena, f.generic_params, map);
            const params = try cloneList(arena, f.params, map);
            const return_type = if (f.return_type) |r| try cloneNode(arena, r, map) else null;
            const body = try cloneNode(arena, f.body, map);
            return appendClone(arena, idx, map, .{ .fn_decl = .{
                .name = f.name,
                .generic_params = generic_params,
                .params = params,
                .return_type = return_type,
                .body = body,
            } });
        },
        .struct_decl => |s| {
            const generic_params = try cloneList(arena, s.generic_params, map);
            const fields = try cloneList(arena, s.fields, map);
            return appendClone(arena, idx, map, .{ .struct_decl = .{
                .name = s.name,
                .generic_params = generic_params,
                .fields = fields,
            } });
        },
        .enum_decl => |e| {
            const generic_params = try cloneList(arena, e.generic_params, map);
            const variants = try cloneList(arena, e.variants, map);
            return appendClone(arena, idx, map, .{ .enum_decl = .{
                .name = e.name,
                .generic_params = generic_params,
                .variants = variants,
            } });
        },
        .import_decl => |imp| {
            const path = try cloneList(arena, imp.path, map);
            return appendClone(arena, idx, map, .{ .import_decl = .{ .path = path, .alias = imp.alias } });
        },
        .if_expr => |i| {
            const cond = try cloneNode(arena, i.cond, map);
            const then_body = try cloneNode(arena, i.then_body, map);
            const else_body = if (i.else_body) |e| try cloneNode(arena, e, map) else null;
            return appendClone(arena, idx, map, .{ .if_expr = .{
                .cond = cond,
                .then_body = then_body,
                .else_body = else_body,
            } });
        },
        .while_expr => |w| {
            const cond = try cloneNode(arena, w.cond, map);
            const body = try cloneNode(arena, w.body, map);
            return appendClone(arena, idx, map, .{ .while_expr = .{ .cond = cond, .body = body } });
        },
        .for_range => |fr| {
            const start = try cloneNode(arena, fr.start, map);
            const end = try cloneNode(arena, fr.end, map);
            const body = try cloneNode(arena, fr.body, map);
            return appendClone(arena, idx, map, .{ .for_range = .{
                .var_name = fr.var_name,
                .start = start,
                .end = end,
                .body = body,
            } });
        },
        .for_each => |fe| {
            const iterable = try cloneNode(arena, fe.iterable, map);
            const body = try cloneNode(arena, fe.body, map);
            return appendClone(arena, idx, map, .{ .for_each = .{
                .var_name = fe.var_name,
                .iterable = iterable,
                .body = body,
            } });
        },
        .match_expr => |m| {
            const scrutinee = try cloneNode(arena, m.scrutinee, map);
            const arms = try cloneList(arena, m.arms, map);
            return appendClone(arena, idx, map, .{ .match_expr = .{ .scrutinee = scrutinee, .arms = arms } });
        },
        .block => |b| {
            const stmts = try cloneList(arena, b.stmts, map);
            return appendClone(arena, idx, map, .{ .block = .{ .stmts = stmts } });
        },
        .param => |p| {
            const ty = try cloneNode(arena, p.ty, map);
            return appendClone(arena, idx, map, .{ .param = .{ .name = p.name, .ty = ty } });
        },
        .field => |f| {
            const ty = try cloneTypeRepr(arena, f.ty, map);
            return appendClone(arena, idx, map, .{ .field = .{ .name = f.name, .ty = ty } });
        },
        .enum_variant => |v| {
            const fields = try cloneList(arena, v.fields, map);
            return appendClone(arena, idx, map, .{ .enum_variant = .{ .name = v.name, .fields = fields } });
        },
        .match_arm => |a| {
            const pattern = try cloneNode(arena, a.pattern, map);
            const guard = if (a.guard) |g| try cloneNode(arena, g, map) else null;
            const body = try cloneNode(arena, a.body, map);
            return appendClone(arena, idx, map, .{ .match_arm = .{
                .pattern = pattern,
                .guard = guard,
                .body = body,
            } });
        },
        .struct_init_field => |f| {
            const value = try cloneNode(arena, f.value, map);
            return appendClone(arena, idx, map, .{ .struct_init_field = .{ .name = f.name, .value = value } });
        },
        .module => |m| {
            const decls = try cloneList(arena, m.decls, map);
            return appendClone(arena, idx, map, .{ .module = .{ .decls = decls } });
        },
    }
}

/// Clone a type expression (`T`, `&T`, `&mut T`).
fn cloneTypeRepr(
    arena: *AstArena,
    ty: TypeRepr,
    map: *std.AutoHashMapUnmanaged(NodeIdx, NodeIdx),
) std.mem.Allocator.Error!TypeRepr {
    return switch (ty) {
        .plain => |n| .{ .plain = try cloneNode(arena, n, map) },
        .reference => |n| .{ .reference = try cloneNode(arena, n, map) },
        .mut_reference => |n| .{ .mut_reference = try cloneNode(arena, n, map) },
    };
}

/// Clone a node list, preserving order.
fn cloneList(
    arena: *AstArena,
    list: NodeList,
    map: *std.AutoHashMapUnmanaged(NodeIdx, NodeIdx),
) std.mem.Allocator.Error!NodeList {
    var buf: std.ArrayList(NodeIdx) = .empty;
    defer buf.deinit(arena.allocator);
    for (list.indices) |child| {
        try buf.append(arena.allocator, try cloneNode(arena, child, map));
    }
    return arena.allocNodeList(buf.items);
}

/// Append a cloned node and record the original -> clone mapping.
fn appendClone(
    arena: *AstArena,
    original: NodeIdx,
    map: *std.AutoHashMapUnmanaged(NodeIdx, NodeIdx),
    node: Node,
) std.mem.Allocator.Error!NodeIdx {
    const new_idx = try arena.append(node);
    try map.put(arena.allocator, original, new_idx);
    return new_idx;
}

/// Location of a named enum variant within its module.
pub const EnumVariantInfo = struct {
    enum_decl: NodeIdx,
    variant_node: NodeIdx,
    index: u32,
};

/// Scan the module's top-level declarations for the enum declaring a variant
/// named `name`. O(module decls * variants) per lookup — fine for module
/// scale; a registry can replace this when imports land.
pub fn findEnumVariant(arena: *const AstArena, source: []const u8, module_node: NodeIdx, name: []const u8) ?EnumVariantInfo {
    const mod = arena.get(module_node);
    for (mod.module.decls.indices) |decl_idx| {
        const decl = arena.get(decl_idx);
        if (decl.* != .enum_decl) continue;
        for (decl.enum_decl.variants.indices, 0..) |variant_idx, i| {
            const variant = arena.get(variant_idx);
            if (std.mem.eql(u8, variant.enum_variant.name.slice(source), name)) {
                return .{
                    .enum_decl = decl_idx,
                    .variant_node = variant_idx,
                    .index = @intCast(i),
                };
            }
        }
    }
    return null;
}
