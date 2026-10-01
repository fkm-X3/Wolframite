const std = @import("std");
const ast = @import("../parser/ast.zig");
const StringRef = ast.StringRef;
const NodeIdx = ast.NodeIdx;
const types = @import("types.zig");
const TypeIdx = types.TypeIdx;

/// `function` is a value symbol: a `fn` name used in expression position is a
/// first-class function value, not a namespace entry. There is no `class`/
/// `interface` kind — polymorphism is comptime generics.
///
/// `prelude_fn` is a name the resolver predeclares from `compiler/prelude.zig`.
/// It is never bound by a declaration, has no `decl_node` pointing into the
/// AST, and lowers to an extern call rather than a Wolframite `fn` — so every
/// pass that walks symbols has to handle it explicitly instead of assuming
/// `.function` implies a body.
pub const SymbolKind = enum(u8) {
    local,
    param,
    function,
    struct_type,
    enum_type,
    generic_param,
    module,
    prelude_fn,
};

/// Which prelude entry a `prelude_fn` symbol denotes. Index into
/// `compiler/prelude.zig`'s roster; `std.math.maxInt(u8)` would fit in 8 bits,
/// but the roster is an explicit small list rather than a packed bitfield so
/// adding an entry does not change the layout.
pub const PreludeSlot = struct {
    index: u8,

    pub const none: PreludeSlot = .{ .index = std.math.maxInt(u8) };
};

pub const Symbol = struct {
    name: StringRef,
    kind: SymbolKind,
    decl_node: NodeIdx,
    type_idx: TypeIdx,
    /// Set only for `.prelude_fn`; `PreludeSlot.none` otherwise.
    prelude: PreludeSlot = PreludeSlot.none,

    /// The name to print in a diagnostic.
    ///
    /// A `name` is a `StringRef` into the program's source, and a prelude
    /// symbol has no source text at all — its name lives in the roster. Reading
    /// `name.slice` on a prelude symbol would report whatever the first
    /// characters of the program happen to be, so anything that formats a
    /// symbol name goes through here instead.
    pub fn displayName(self: Symbol, source: []const u8) []const u8 {
        if (self.kind == .prelude_fn and self.prelude.index != PreludeSlot.none.index) {
            const roster = @import("../prelude.zig").roster;
            if (self.prelude.index < roster.len) return roster[self.prelude.index].name;
        }
        return self.name.slice(source);
    }
};

pub const Scope = struct {
    symbols: std.StringHashMapUnmanaged(Symbol),
    parent: ?u32,
    depth: u32,
};

pub const ScopeStack = struct {
    scopes: std.ArrayListUnmanaged(Scope),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScopeStack {
        return .{
            .scopes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScopeStack) void {
        for (self.scopes.items) |*scope| {
            scope.symbols.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
    }

    pub fn pushScope(self: *ScopeStack, parent: ?u32) !u32 {
        const idx: u32 = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{
            .symbols = .empty,
            .parent = parent,
            .depth = if (parent) |p| self.scopes.items[@as(usize, @intCast(p))].depth + 1 else 0,
        });
        return idx;
    }

    pub fn popScope(self: *ScopeStack) void {
        var scope = &self.scopes.items[self.scopes.items.len - 1];
        scope.symbols.deinit(self.allocator);
        _ = self.scopes.pop();
    }

    pub fn insert(self: *ScopeStack, name: []const u8, symbol: Symbol) !void {
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.symbols.put(self.allocator, name, symbol);
    }

    pub fn lookup(self: *const ScopeStack, name: []const u8, start_scope: u32) ?Symbol {
        var idx: u32 = start_scope;
        while (true) {
            const scope = &self.scopes.items[@as(usize, @intCast(idx))];
            if (scope.symbols.get(name)) |sym| {
                return sym;
            }
            if (scope.parent) |p| {
                idx = p;
            } else {
                break;
            }
        }
        return null;
    }

    pub fn lookupCurrent(self: *const ScopeStack, name: []const u8) ?Symbol {
        if (self.scopes.items.len == 0) return null;
        const current = self.scopes.getLast();
        return current.symbols.get(name);
    }

    pub fn depth(self: *const ScopeStack, scope_idx: u32) u32 {
        return self.scopes.items[@as(usize, @intCast(scope_idx))].depth;
    }

    pub fn currentScope(self: *const ScopeStack) u32 {
        return @intCast(self.scopes.items.len - 1);
    }

    pub fn scopeCount(self: *const ScopeStack) usize {
        return self.scopes.items.len;
    }
};

test "scope stack basic operations" {
    var stack = ScopeStack.init(std.testing.allocator);
    defer stack.deinit();

    const global = try stack.pushScope(null);
    try std.testing.expectEqual(@as(u32, 0), global);
    try std.testing.expectEqual(@as(usize, 1), stack.scopeCount());

    try stack.insert("x", .{
        .name = .{ .start = 0, .end = 1 },
        .kind = .local,
        .decl_node = @enumFromInt(1),
        .type_idx = @enumFromInt(0),
    });

    const sym = stack.lookup("x", stack.currentScope()).?;
    try std.testing.expectEqual(SymbolKind.local, sym.kind);
    try std.testing.expect(stack.lookup("y", stack.currentScope()) == null);
}

test "scope stack nested scopes" {
    var stack = ScopeStack.init(std.testing.allocator);
    defer stack.deinit();

    const global = try stack.pushScope(null);
    try stack.insert("a", .{
        .name = .{ .start = 0, .end = 1 },
        .kind = .function,
        .decl_node = @enumFromInt(1),
        .type_idx = @enumFromInt(0),
    });

    const inner = try stack.pushScope(global);
    try stack.insert("b", .{
        .name = .{ .start = 0, .end = 1 },
        .kind = .local,
        .decl_node = @enumFromInt(2),
        .type_idx = @enumFromInt(0),
    });

    try std.testing.expect(stack.lookup("a", inner) != null);
    try std.testing.expect(stack.lookup("b", inner) != null);
    try std.testing.expect(stack.lookup("b", global) == null);
}

test "scope stack depth" {
    var stack = ScopeStack.init(std.testing.allocator);
    defer stack.deinit();

    const s0 = try stack.pushScope(null);
    try std.testing.expectEqual(@as(u32, 0), stack.depth(s0));
    const s1 = try stack.pushScope(s0);
    try std.testing.expectEqual(@as(u32, 1), stack.depth(s1));
    const s2 = try stack.pushScope(s1);
    try std.testing.expectEqual(@as(u32, 2), stack.depth(s2));
}
