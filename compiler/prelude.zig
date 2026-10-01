//! The prelude roster: names that resolve without a declaration, and the
//! runtime symbols they lower to.
//!
//! There is no prelude source file that gets parsed. A prelude function is not
//! a `fn` the program can introspect, shadow, or pass around — it is a row in
//! this table, plus the three passes that read it: the resolver predeclares the
//! name, the typechecker checks the call against the declared signature, and
//! the lowerer emits the extern call. Keeping it as data rather than synthetic
//! AST is what makes the reservation airtight: there is no declaration a program
//! can find and collide with, and no body to lower.
//!
//! Composition functions (`id`, `pipe`, `compose`, `curry`, `uncurry`) belong in
//! this table too, but they are source expansions over generic functions and
//! closures, and neither of those lowers yet. Adding them before then would
//! mean a name that resolves and typechecks and then fails in codegen, which is
//! worse than not having it at all.

const std = @import("std");

/// The parameter types a prelude function can accept. Kept as an enum rather
/// than a `TypeIdx` because the roster is `comptime` data and type-pool indices
/// do not exist until a program is being checked.
pub const ParamType = enum {
    string,
    i64,
    u64,
    f64,
    void,
};

/// One prelude entry: the name a program writes, the runtime symbol the
/// lowerer calls, and the signature the typechecker enforces.
pub const PreludeFn = struct {
    name: []const u8,
    symbol: []const u8,
    params: []const ParamType,
    return_type: ParamType,

    /// Whether the call has no result to use. `print` is `void`; nothing in
    /// the roster returns a value a program can bind yet.
    pub fn returnsVoid(self: PreludeFn) bool {
        return self.return_type == .void;
    }
};

/// Every prelude function the compiler knows about, in roster order.
///
/// Order is stable so diagnostics and tests can refer to an index. New entries
/// are appended; removing one is a language change.
pub const roster: []const PreludeFn = &.{
    .{
        .name = "print",
        .symbol = "wfr_std_print",
        .params = &.{.string},
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

const testing = std.testing;

test "print is the roster's IO entry point" {
    const print = lookup("print").?;
    try testing.expectEqualStrings("wfr_std_print", print.symbol);
    try testing.expectEqual(@as(usize, 1), print.params.len);
    try testing.expectEqual(ParamType.string, print.params[0]);
    try testing.expect(print.returnsVoid());
}

test "an ordinary name is not in the roster" {
    try testing.expectEqual(@as(?PreludeFn, null), lookup("println"));
    try testing.expectEqual(@as(?PreludeFn, null), lookup("add"));
    try testing.expectEqual(@as(?PreludeFn, null), lookup(""));
    try testing.expect(!isReserved("println"));
}

test "roster entries have unique names and non-empty symbols" {
    for (roster, 0..) |entry, i| {
        try testing.expect(entry.name.len > 0);
        try testing.expect(entry.symbol.len > 0);
        for (roster[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.name, other.name));
        }
    }
}

test "every roster symbol lives in the runtime's namespace" {
    for (roster) |entry| {
        try testing.expect(std.mem.startsWith(u8, entry.symbol, "wfr_std_"));
    }
}
