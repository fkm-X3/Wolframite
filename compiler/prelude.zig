//! The prelude roster: names that resolve without a declaration, and what
//! they mean.
//!
//! There is no prelude source file that gets parsed. A prelude function is not
//! a `fn` the program can introspect, shadow, or pass around — it is a row in
//! this table, plus the three passes that read it: the resolver predeclares the
//! name, the typechecker checks the call, and the lowerer emits it. Keeping it
//! as data rather than synthetic AST is what makes the reservation airtight:
//! there is no declaration a program can find and collide with, and no body to
//! lower.
//!
//! Two kinds of entry live here. An **IO** entry (`print`) names a runtime
//! symbol the lowerer calls directly. A **composition** entry (`id`, `pipe`,
//! `compose`, `curry`, `uncurry`) has no runtime identity at all: it is a
//! source expansion over ordinary functions and closures (docs/semantics.md
//! §9.2 R31), so the typechecker derives its result type from the operands and
//! the lowerer expands it into direct calls and stack env records.

const std = @import("std");

/// What a prelude entry is.
pub const Kind = enum {
    /// An IO entry point: a runtime symbol the lowerer calls directly.
    io,
    /// A composition entry point: a source expansion over functions and
    /// closures, lowered through the closure machinery (R31).
    composition,
};

/// The expansion of a composition prelude entry (R31).
///
/// Every shape is generic: the typechecker instantiates it per concrete
/// operand type, and the lowerer expands it per call site.
pub const Shape = enum {
    /// `id(x)` ≡ `x`.
    id,
    /// `pipe(x, f)` ≡ `f(x)`.
    pipe,
    /// `compose(f, g)(x)` ≡ `f(g(x))` — right-to-left, exactly 2-ary.
    compose,
    /// `curry(f)(a)(b)` ≡ `f(a, b)` — front-to-left, exactly 2-ary.
    curry,
    /// `uncurry(h)(a, b)` ≡ `h(a)(b)` — exactly 2-ary.
    uncurry,
};

/// The parameter types an IO prelude function can accept. Kept as an enum
/// rather than a `TypeIdx` because the roster is `comptime` data and type-pool
/// indices do not exist until a program is being checked.
pub const ParamType = enum {
    string,
    i64,
    u64,
    f64,
    void,
};

/// One prelude entry: the name a program writes, what kind of thing it is,
/// and the signature the typechecker enforces.
pub const PreludeFn = struct {
    name: []const u8,
    kind: Kind,
    /// The runtime symbol an IO entry lowers to; null for a composition entry,
    /// which has no runtime identity (R31c).
    symbol: ?[]const u8,
    /// The composition expansion shape; null for an IO entry.
    shape: ?Shape,
    /// The parameter types an IO entry accepts. A composition entry is generic
    /// and has no fixed parameter list.
    params: []const ParamType,
    /// The IO entry's return type. A composition entry is generic and derives
    /// its result type from the operands.
    return_type: ParamType,

    /// Whether the call has no result to use. `print` is `void`; a
    /// composition entry's result type depends on its operands.
    pub fn returnsVoid(self: PreludeFn) bool {
        return self.kind == .io and self.return_type == .void;
    }
};

/// Every prelude function the compiler knows about, in roster order.
///
/// Order is stable so diagnostics and tests can refer to an index. New entries
/// are appended; removing one is a language change.
pub const roster: []const PreludeFn = &.{
    .{
        .name = "print",
        .kind = .io,
        .symbol = "wfr_std_print",
        .shape = null,
        .params = &.{.string},
        .return_type = .void,
    },
    .{
        .name = "id",
        .kind = .composition,
        .symbol = null,
        .shape = .id,
        .params = &.{},
        .return_type = .void,
    },
    .{
        .name = "pipe",
        .kind = .composition,
        .symbol = null,
        .shape = .pipe,
        .params = &.{},
        .return_type = .void,
    },
    .{
        .name = "compose",
        .kind = .composition,
        .symbol = null,
        .shape = .compose,
        .params = &.{},
        .return_type = .void,
    },
    .{
        .name = "curry",
        .kind = .composition,
        .symbol = null,
        .shape = .curry,
        .params = &.{},
        .return_type = .void,
    },
    .{
        .name = "uncurry",
        .kind = .composition,
        .symbol = null,
        .shape = .uncurry,
        .params = &.{},
        .return_type = .void,
    },
};

/// The prelude entry named `name`, or null when `name` is ordinary.
pub fn lookup(name: []const u8) ?PreludeFn {
    for (roster) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Whether `name` is reserved by the prelude and therefore cannot be declared
/// or bound by a program (ADR-0001 §4: shadowing a prelude name would silently
/// disable the direct-call fast path).
pub fn isReserved(name: []const u8) bool {
    return lookup(name) != null;
}

/// The expansion shape of the composition entry named `name`, or null when the
/// name is not a composition entry.
pub fn compositionShape(name: []const u8) ?Shape {
    const entry = lookup(name) orelse return null;
    if (entry.kind != .composition) return null;
    return entry.shape;
}

const testing = std.testing;

test "print is the roster's IO entry point" {
    const print = lookup("print").?;
    try testing.expectEqual(Kind.io, print.kind);
    try testing.expectEqualStrings("wfr_std_print", print.symbol.?);
    try testing.expectEqual(@as(usize, 1), print.params.len);
    try testing.expectEqual(ParamType.string, print.params[0]);
    try testing.expect(print.returnsVoid());
}

test "the composition roster is the five ADR-0001 entries" {
    const expected = [_]struct { name: []const u8, shape: Shape }{
        .{ .name = "id", .shape = .id },
        .{ .name = "pipe", .shape = .pipe },
        .{ .name = "compose", .shape = .compose },
        .{ .name = "curry", .shape = .curry },
        .{ .name = "uncurry", .shape = .uncurry },
    };
    var seen: usize = 0;
    for (roster) |entry| {
        if (entry.kind != .composition) continue;
        try testing.expect(seen < expected.len);
        try testing.expectEqualStrings(expected[seen].name, entry.name);
        try testing.expectEqual(expected[seen].shape, entry.shape.?);
        seen += 1;
    }
    try testing.expectEqual(expected.len, seen);
}

test "a composition entry has no runtime symbol" {
    for (roster) |entry| {
        if (entry.kind != .composition) continue;
        try testing.expectEqual(@as(?[]const u8, null), entry.symbol);
        try testing.expect(entry.shape != null);
        try testing.expect(!entry.returnsVoid());
    }
}

test "an ordinary name is not in the roster" {
    try testing.expectEqual(@as(?PreludeFn, null), lookup("println"));
    try testing.expectEqual(@as(?PreludeFn, null), lookup("add"));
    try testing.expectEqual(@as(?PreludeFn, null), lookup(""));
    try testing.expect(!isReserved("println"));
}

test "every prelude name is reserved" {
    for (roster) |entry| {
        try testing.expect(isReserved(entry.name));
    }
    try testing.expectEqual(Shape.curry, compositionShape("curry").?);
    try testing.expectEqual(@as(?Shape, null), compositionShape("print"));
    try testing.expectEqual(@as(?Shape, null), compositionShape("add"));
}

test "roster entries have unique names and non-empty symbols" {
    for (roster, 0..) |entry, i| {
        try testing.expect(entry.name.len > 0);
        if (entry.kind == .io) try testing.expect(entry.symbol.?.len > 0);
        for (roster[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.name, other.name));
        }
    }
}

test "every IO roster symbol lives in the runtime's namespace" {
    for (roster) |entry| {
        if (entry.kind != .io) continue;
        try testing.expect(std.mem.startsWith(u8, entry.symbol.?, "wfr_std_"));
    }
}
