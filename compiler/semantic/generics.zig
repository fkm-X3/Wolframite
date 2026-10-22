//! Comptime generics: instance identity, mangled names, and type substitution.
//!
//! docs/semantics.md §7 spells out the model:
//!
//! - §7.2 (R20) — an *instance* is `(decl_node, [A0..Ak])`, and instance
//!   identity is by def-eq of the type arguments, not by the identity of the
//!   `TypeIdx` that happens to hold them.
//! - §7.3 (R21) — instantiation is lazy and cached: the compiler builds
//!   `{Pi -> Ai}`, clones the generic body, and type-checks the clone.
//! - §7.4 (R22) — an instance function's symbol is `<base>__<mangled args>`,
//!   with the per-type mangling table below.
//! - §7.6 (R24) — a generic call's type arguments are inferred one-way, from
//!   the argument types into the parameter types.
//!
//! This module holds the parts that need no compiler state: mangling,
//! substitution, structural hashing, and template unification.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types_mod = @import("types.zig");

const Allocator = std.mem.Allocator;
const NodeIdx = ast.NodeIdx;
const StringRef = ast.StringRef;
const TypeIdx = types_mod.TypeIdx;
const SemType = types_mod.SemType;
const TypePool = types_mod.TypePool;

/// The template of a generic declaration: its generic parameters, the
/// parameter types written with `generic_param` placeholders, and the return
/// type template (docs/semantics.md §7.1, R19d).
///
/// The template is resolved once per declaration and shared by every
/// instance; substitution (R21 step 2) turns it into concrete types.
pub const GenericInfo = struct {
    /// The generic declaration this template belongs to.
    decl: NodeIdx,
    /// The generic parameter names, in declaration order.
    param_names: []const StringRef,
    /// The `generic_param` nodes of the declaration, in declaration order.
    param_nodes: []const NodeIdx,
    /// The parameter types, with `generic_param` placeholders, in declaration
    /// order.
    template_params: []const TypeIdx,
    /// The return type template; `void` when the declaration has no
    /// annotation.
    template_return: TypeIdx,

    pub fn paramCount(self: GenericInfo) usize {
        return self.param_names.len;
    }
};

/// One monomorphized instance of a generic declaration (R20/R21).
///
/// A `fn` instance owns a clone of the generic declaration: the clone is
/// type-checked with the type arguments bound and lowered as its own
/// function, named `mangled`.
pub const GenericInstance = struct {
    /// The generic declaration the instance was made from.
    decl: NodeIdx,
    /// The concrete type arguments.
    args: []const TypeIdx,
    /// The mangled instance symbol (R22).
    mangled: []const u8,
    /// The cloned declaration node — a `fn_decl` copy that stands in for the
    /// generic body.
    clone: NodeIdx,
    /// The concrete signature of the instance: a `function` type whose
    /// parameter and return types have the arguments substituted in.
    sig: TypeIdx,
    /// The concrete return type.
    return_type: TypeIdx,
};

/// A comptime value: the result of evaluating a comptime expression
/// (docs/semantics.md §7.5, R23a).
///
/// The six comptime builtins evaluate to one of these: `@hasField` to a
/// `bool`, `@sizeOf`/`@alignOf` to an `int`, `@typeOf` to a `type_value`, and
/// `@field` to the value of the named field.
pub const ComptimeValue = union(enum) {
    /// The expression has no comptime value: it is a runtime value.
    none,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    /// A type value: the semantic type it denotes.
    type_value: TypeIdx,
};

// ========================================================================
// Mangling (R22)
// ========================================================================

/// Builds the mangled spelling of instance symbols (docs/semantics.md §7.4).
///
/// The mangled name only has to be stable and unique enough for assembly
/// output: instance *identity* is the type-argument-keyed cache, not the
/// name.
pub const Mangler = struct {
    arena: *const ast.AstArena,
    source: []const u8,
    pool: *const TypePool,
    gpa: Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(
        arena: *const ast.AstArena,
        source: []const u8,
        pool: *const TypePool,
        gpa: Allocator,
    ) Mangler {
        return .{ .arena = arena, .source = source, .pool = pool, .gpa = gpa };
    }

    pub fn deinit(self: *Mangler) void {
        self.out.deinit(self.gpa);
    }

    /// The mangled fragment of a single type.
    ///
    /// | type | mangle |
    /// |---|---|
    /// | `i8`..`i64`, `u8`..`u64`, `f32`, `f64` | the spelled name, e.g. `i32` |
    /// | `bool` | `b` |
    /// | `String` | `str` |
    /// | pointer `*T` | `pt_<T>` |
    /// | fn type | `fn_<ret>__<arg1>_<arg2>...` |
    /// | struct/enum instance | `<name>_<mangled args>` |
    pub fn mangleType(self: *Mangler, ty: TypeIdx) !void {
        switch (self.pool.get(ty)) {
            .void => try self.out.appendSlice(self.gpa, "void"),
            .bool_type => try self.out.appendSlice(self.gpa, "b"),
            .int => |i| try self.out.print(self.gpa, "{s}{d}", .{
                if (i.signed) "i" else "u", i.bits,
            }),
            .float => |f| try self.out.appendSlice(self.gpa, @tagName(f)),
            .string_type => try self.out.appendSlice(self.gpa, "str"),
            .pointer => |elem| {
                try self.out.appendSlice(self.gpa, "pt_");
                try self.mangleType(elem);
            },
            .function => |f| {
                try self.out.appendSlice(self.gpa, "fn_");
                try self.mangleType(f.return_type);
                try self.out.appendSlice(self.gpa, "__");
                for (f.param_types, 0..) |p, i| {
                    if (i > 0) try self.out.append(self.gpa, '_');
                    try self.mangleType(p);
                }
            },
            .struct_type => |decl| try self.out.appendSlice(self.gpa, self.declName(decl)),
            .applied_struct => |a| {
                try self.out.appendSlice(self.gpa, self.declName(a.decl));
                for (a.args) |arg| {
                    try self.out.append(self.gpa, '_');
                    try self.mangleType(arg);
                }
            },
            .enum_type => |decl| try self.out.appendSlice(self.gpa, self.declName(decl)),
            .applied_enum => |a| {
                try self.out.appendSlice(self.gpa, self.declName(a.decl));
                for (a.args) |arg| {
                    try self.out.append(self.gpa, '_');
                    try self.mangleType(arg);
                }
            },
            .applied_fn => |a| try self.mangleType(a.sig),
            .array => |a| {
                try self.out.appendSlice(self.gpa, "arr_");
                try self.mangleType(a.elem);
            },
            .slice => |elem| {
                try self.out.appendSlice(self.gpa, "sl_");
                try self.mangleType(elem);
            },
            .generic_param => |gp| try self.out.print(self.gpa, "gp_{d}", .{gp.index}),
            .type_value => try self.out.appendSlice(self.gpa, "tv"),
            .inferred => try self.out.appendSlice(self.gpa, "inf"),
        }
    }

    /// The mangled instance symbol: `<base>__<mangled args...>` (R22).
    ///
    /// `first[i32]` becomes `first__i32`; `Pair[i32, f64]` becomes
    /// `Pair__i32_f64`.
    pub fn mangleInstance(self: *Mangler, base: []const u8, args: []const TypeIdx) !void {
        try self.out.appendSlice(self.gpa, base);
        try self.out.appendSlice(self.gpa, "__");
        for (args, 0..) |arg, i| {
            if (i > 0) try self.out.append(self.gpa, '_');
            try self.mangleType(arg);
        }
    }

    /// The declared name of a struct/enum/fn declaration.
    fn declName(self: *const Mangler, decl: NodeIdx) []const u8 {
        const node = self.arena.get(decl);
        return switch (node.*) {
            .struct_decl => |s| s.name.slice(self.source),
            .enum_decl => |e| e.name.slice(self.source),
            .fn_decl => |f| f.name.slice(self.source),
            else => "anon",
        };
    }
};

// ========================================================================
// Substitution (R21 step 2)
// ========================================================================

/// Substitute the type arguments into a template type, recursively.
///
/// A `generic_param` becomes its argument; a pointer, function type, or
/// applied struct/enum is rebuilt with its parts substituted. A type that
/// mentions no generic parameter is returned unchanged, so an instance of a
/// non-generic type shares the original `TypeIdx`.
pub fn substType(pool: *TypePool, ty: TypeIdx, args: []const TypeIdx) !TypeIdx {
    switch (pool.get(ty)) {
        .generic_param => |gp| {
            if (gp.index < args.len) return args[gp.index];
            return ty;
        },
        .pointer => |elem| {
            const new_elem = try substType(pool, elem, args);
            if (new_elem == elem) return ty;
            return pool.add(.{ .pointer = new_elem });
        },
        .function => |f| {
            const params = try pool.allocator.alloc(TypeIdx, f.param_types.len);
            errdefer pool.allocator.free(params);
            var changed = false;
            for (f.param_types, 0..) |p, i| {
                params[i] = try substType(pool, p, args);
                if (params[i] != p) changed = true;
            }
            const ret = try substType(pool, f.return_type, args);
            if (!changed and ret == f.return_type) {
                pool.allocator.free(params);
                return ty;
            }
            const owned = try pool.allocator.alloc(TypeIdx, params.len);
            @memcpy(owned, params);
            pool.allocator.free(params);
            return pool.add(.{ .function = .{ .param_types = owned, .return_type = ret } });
        },
        .applied_struct => |a| {
            const new_args = try pool.allocator.alloc(TypeIdx, a.args.len);
            var changed = false;
            for (a.args, 0..) |x, i| {
                new_args[i] = try substType(pool, x, args);
                if (new_args[i] != x) changed = true;
            }
            if (!changed) {
                pool.allocator.free(new_args);
                return ty;
            }
            return pool.add(.{ .applied_struct = .{ .decl = a.decl, .args = new_args } });
        },
        .applied_enum => |a| {
            const new_args = try pool.allocator.alloc(TypeIdx, a.args.len);
            var changed = false;
            for (a.args, 0..) |x, i| {
                new_args[i] = try substType(pool, x, args);
                if (new_args[i] != x) changed = true;
            }
            if (!changed) {
                pool.allocator.free(new_args);
                return ty;
            }
            return pool.add(.{ .applied_enum = .{ .decl = a.decl, .args = new_args } });
        },
        .applied_fn => |a| {
            const new_args = try pool.allocator.alloc(TypeIdx, a.args.len);
            var changed = false;
            for (a.args, 0..) |x, i| {
                new_args[i] = try substType(pool, x, args);
                if (new_args[i] != x) changed = true;
            }
            const new_sig = try substType(pool, a.sig, args);
            if (!changed and new_sig == a.sig) {
                pool.allocator.free(new_args);
                return ty;
            }
            return pool.add(.{ .applied_fn = .{ .decl = a.decl, .args = new_args, .sig = new_sig } });
        },
        else => return ty,
    }
}

// ========================================================================
// Identity (R20a)
// ========================================================================

/// A structural hash of a type.
///
/// Instance identity is by def-eq of the type arguments (R20a), so the cache
/// key hashes the *shape* of a type rather than the `TypeIdx` that holds it:
/// two sites that name the same instance must land on the same key even when
/// they built separate `TypeIdx` values for it.
pub fn typeHash(pool: *const TypePool, ty: TypeIdx) u64 {
    var h: u64 = 0xcbf29ce484222325;
    hashType(pool, ty, &h, 0);
    return h;
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

fn hashType(pool: *const TypePool, ty: TypeIdx, h: *u64, depth: u32) void {
    // A cycle in the type graph cannot happen today, but the depth guard
    // keeps the hash total if one ever does.
    if (depth > 8) {
        h.* = mix(h.*, 0xdead);
        return;
    }
    switch (pool.get(ty)) {
        .void => h.* = mix(h.*, 1),
        .bool_type => h.* = mix(h.*, 2),
        .int => |i| {
            h.* = mix(h.*, 3);
            h.* = mix(h.*, if (i.signed) 1 else 0);
            h.* = mix(h.*, i.bits);
        },
        .float => |f| {
            h.* = mix(h.*, 4);
            h.* = mix(h.*, @intFromEnum(f));
        },
        .string_type => h.* = mix(h.*, 5),
        .pointer => |elem| {
            h.* = mix(h.*, 6);
            hashType(pool, elem, h, depth + 1);
        },
        .function => |f| {
            h.* = mix(h.*, 7);
            hashType(pool, f.return_type, h, depth + 1);
            for (f.param_types) |p| hashType(pool, p, h, depth + 1);
        },
        .struct_type => |decl| {
            h.* = mix(h.*, 8);
            h.* = mix(h.*, @intFromEnum(decl));
        },
        .applied_struct => |a| {
            h.* = mix(h.*, 9);
            h.* = mix(h.*, @intFromEnum(a.decl));
            for (a.args) |x| hashType(pool, x, h, depth + 1);
        },
        .enum_type => |decl| {
            h.* = mix(h.*, 10);
            h.* = mix(h.*, @intFromEnum(decl));
        },
        .applied_enum => |a| {
            h.* = mix(h.*, 11);
            h.* = mix(h.*, @intFromEnum(a.decl));
            for (a.args) |x| hashType(pool, x, h, depth + 1);
        },
        .applied_fn => |a| {
            h.* = mix(h.*, 12);
            h.* = mix(h.*, @intFromEnum(a.decl));
            for (a.args) |x| hashType(pool, x, h, depth + 1);
            hashType(pool, a.sig, h, depth + 1);
        },
        .array => |a| {
            h.* = mix(h.*, 13);
            hashType(pool, a.elem, h, depth + 1);
            h.* = mix(h.*, a.size orelse 0);
        },
        .slice => |elem| {
            h.* = mix(h.*, 14);
            hashType(pool, elem, h, depth + 1);
        },
        .generic_param => |gp| {
            h.* = mix(h.*, 15);
            h.* = mix(h.*, gp.index);
        },
        .type_value => h.* = mix(h.*, 17),
        .inferred => h.* = mix(h.*, 16),
    }
}

/// Structural equality of two types (R20a def-eq).
pub fn typesEqual(pool: *const TypePool, a: TypeIdx, b: TypeIdx) bool {
    if (a == b) return true;
    const ta = pool.get(a);
    const tb = pool.get(b);
    if (@as(std.meta.Tag(SemType), ta) != @as(std.meta.Tag(SemType), tb)) return false;
    return switch (ta) {
        .void, .bool_type, .string_type, .inferred => true,
        .int => |ia| ia.signed == tb.int.signed and ia.bits == tb.int.bits,
        .float => |fa| fa == tb.float,
        .pointer => |pa| typesEqual(pool, pa, tb.pointer),
        .function => |fa| blk: {
            const fb = tb.function;
            if (fa.param_types.len != fb.param_types.len) break :blk false;
            if (!typesEqual(pool, fa.return_type, fb.return_type)) break :blk false;
            for (fa.param_types, fb.param_types) |pa, pb| {
                if (!typesEqual(pool, pa, pb)) break :blk false;
            }
            break :blk true;
        },
        .struct_type => |da| da == tb.struct_type,
        .applied_struct => |aa| aa.decl == tb.applied_struct.decl and
            typeListsEqual(pool, aa.args, tb.applied_struct.args),
        .enum_type => |da| da == tb.enum_type,
        .applied_enum => |aa| aa.decl == tb.applied_enum.decl and
            typeListsEqual(pool, aa.args, tb.applied_enum.args),
        .applied_fn => |aa| aa.decl == tb.applied_fn.decl and
            typeListsEqual(pool, aa.args, tb.applied_fn.args) and
            typesEqual(pool, aa.sig, tb.applied_fn.sig),
        .array => |aa| aa.size == tb.array.size and typesEqual(pool, aa.elem, tb.array.elem),
        .slice => |ea| typesEqual(pool, ea, tb.slice),
        .generic_param => |ga| ga.index == tb.generic_param.index,
        .type_value => true,
    };
}

fn typeListsEqual(pool: *const TypePool, a: []const TypeIdx, b: []const TypeIdx) bool {
    if (a.len != b.len) return false;
    for (a, b) |pa, pb| {
        if (!typesEqual(pool, pa, pb)) return false;
    }
    return true;
}

// ========================================================================
// Type-argument inference (R24)
// ========================================================================

/// The type arguments collected while inferring a generic call (R24a).
///
/// A binding is *one-directional*: the argument type flows into the
/// parameter's `generic_param` placeholder, never the other way round.
pub const Bindings = struct {
    /// The bound type argument per generic parameter; `null` while unbound.
    bound: []?TypeIdx,
    /// Set when two arguments disagree about the same parameter.
    conflict: bool = false,
    /// The generic parameter the conflict was found at.
    conflict_index: u32 = 0,

    pub fn init(allocator: Allocator, count: usize) !Bindings {
        const bound = try allocator.alloc(?TypeIdx, count);
        @memset(bound, null);
        return .{ .bound = bound };
    }

    pub fn deinit(self: *Bindings, allocator: Allocator) void {
        allocator.free(self.bound);
    }

    /// Bind a generic parameter, reporting a conflict when it is already
    /// bound to a different type.
    pub fn bind(self: *Bindings, pool: *const TypePool, index: u32, ty: TypeIdx) void {
        if (index >= self.bound.len) return;
        if (self.bound[index]) |existing| {
            if (!typesEqual(pool, existing, ty)) {
                self.conflict = true;
                self.conflict_index = index;
            }
            return;
        }
        self.bound[index] = ty;
    }
};

/// Unify a template (parameter) type with a concrete argument type
/// (R24a).
///
/// Only the template's `generic_param` placeholders absorb a type; equal
/// occurrences unify to one type and a conflict is reported through
/// `bindings`.
pub fn unifyTemplate(pool: *const TypePool, template: TypeIdx, arg: TypeIdx, bindings: *Bindings) void {
    switch (pool.get(template)) {
        .generic_param => |gp| bindings.bind(pool, gp.index, arg),
        .pointer => |elem| {
            const arg_sem = pool.get(arg);
            if (arg_sem == .pointer) unifyTemplate(pool, elem, arg_sem.pointer, bindings);
        },
        .function => |tf| {
            const arg_sem = pool.get(arg);
            if (arg_sem != .function) return;
            const af = arg_sem.function;
            if (af.param_types.len != tf.param_types.len) return;
            for (tf.param_types, af.param_types) |tp, ap| {
                unifyTemplate(pool, tp, ap, bindings);
            }
            unifyTemplate(pool, tf.return_type, af.return_type, bindings);
        },
        .applied_struct => |ta| {
            const arg_sem = pool.get(arg);
            if (arg_sem != .applied_struct) return;
            const aa = arg_sem.applied_struct;
            if (aa.args.len != ta.args.len) return;
            for (ta.args, aa.args) |x, y| unifyTemplate(pool, x, y, bindings);
        },
        .applied_enum => |ta| {
            const arg_sem = pool.get(arg);
            if (arg_sem != .applied_enum) return;
            const aa = arg_sem.applied_enum;
            if (aa.args.len != ta.args.len) return;
            for (ta.args, aa.args) |x, y| unifyTemplate(pool, x, y, bindings);
        },
        else => {},
    }
}

test "mangle: instances follow the R22 table" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();

    const i32_ty = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    const f64_ty = try pool.add(.{ .float = .f64 });
    const bool_ty = try pool.add(.bool_type);
    const str_ty = try pool.add(.string_type);

    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var mangler = Mangler.init(&arena, "", &pool, std.testing.allocator);
    defer mangler.deinit();

    try mangler.mangleInstance("first", &.{i32_ty});
    try std.testing.expectEqualStrings("first__i32", mangler.out.items);

    mangler.out.clearRetainingCapacity();
    try mangler.mangleInstance("map", &.{i32_ty});
    try std.testing.expectEqualStrings("map__i32", mangler.out.items);

    mangler.out.clearRetainingCapacity();
    try mangler.mangleInstance("pair", &.{ i32_ty, f64_ty });
    try std.testing.expectEqualStrings("pair__i32_f64", mangler.out.items);

    mangler.out.clearRetainingCapacity();
    try mangler.mangleInstance("flag", &.{bool_ty});
    try std.testing.expectEqualStrings("flag__b", mangler.out.items);

    mangler.out.clearRetainingCapacity();
    try mangler.mangleInstance("name", &.{str_ty});
    try std.testing.expectEqualStrings("name__str", mangler.out.items);
}

test "mangle: a fn type argument" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();

    const i32_ty = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    const params = try pool.allocator.alloc(TypeIdx, 1);
    params[0] = i32_ty;
    const fn_ty = try pool.add(.{ .function = .{ .param_types = params, .return_type = i32_ty } });

    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var mangler = Mangler.init(&arena, "", &pool, std.testing.allocator);
    defer mangler.deinit();

    try mangler.mangleInstance("map", &.{fn_ty});
    try std.testing.expectEqualStrings("map__fn_i32__i32", mangler.out.items);
}

test "subst: a generic parameter becomes its argument" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();

    const i32_ty = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    const gp_ty = try pool.add(.{ .generic_param = .{ .name = .{ .start = 0, .end = 1 }, .index = 0 } });

    const sub = try substType(&pool, gp_ty, &.{i32_ty});
    try std.testing.expectEqual(i32_ty, sub);
}

test "subst: substitution reaches through a pointer" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();

    const i32_ty = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    const gp_ty = try pool.add(.{ .generic_param = .{ .name = .{ .start = 0, .end = 1 }, .index = 0 } });
    const ptr_ty = try pool.add(.{ .pointer = gp_ty });

    const sub = try substType(&pool, ptr_ty, &.{i32_ty});
    try std.testing.expectEqual(i32_ty, pool.get(sub).pointer);
}

test "typeHash: the same shape hashes the same" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();

    const a = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    const b = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    try std.testing.expectEqual(typeHash(&pool, a), typeHash(&pool, b));

    const c = try pool.add(.{ .int = .{ .signed = true, .bits = 64 } });
    try std.testing.expect(typeHash(&pool, a) != typeHash(&pool, c));
}

test "unifyTemplate: one argument binds the parameter" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();

    const i32_ty = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    const f64_ty = try pool.add(.{ .float = .f64 });
    const gp_ty = try pool.add(.{ .generic_param = .{ .name = .{ .start = 0, .end = 1 }, .index = 0 } });

    var bindings = try Bindings.init(std.testing.allocator, 1);
    defer bindings.deinit(std.testing.allocator);

    unifyTemplate(&pool, gp_ty, i32_ty, &bindings);
    try std.testing.expectEqual(@as(?TypeIdx, i32_ty), bindings.bound[0]);
    try std.testing.expect(!bindings.conflict);

    unifyTemplate(&pool, gp_ty, f64_ty, &bindings);
    try std.testing.expect(bindings.conflict);
}
