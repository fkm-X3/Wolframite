//! String lowering.
//!
//! A W `String` is represented as a pointer to a 16-byte block laid out as:
//!
//! ```text
//! [ len: i64 ][ data: u8* ]
//! ```
//!
//! The block is allocated on the stack with `buildAllocaBytes`, so string
//! values are copied by pointer and string literals require no heap
//! allocation. Literal bytes are interned into a per-module pool and emitted
//! NUL-terminated in the `.data` section by the backend.
//!
//! Known simplifications:
//! - No ref counting / freeing: the lowerer never emits a deallocation for
//!   the block.
//! - `len` is a `u64`; the low 32 bits are what the type system exposes.

const std = @import("std");
const api = @import("Tungsten").api;
const ast = @import("../parser/ast.zig");

const Allocator = std.mem.Allocator;

pub const len_offset: u64 = 0;
pub const data_offset: u64 = 8;
pub const total_size: u32 = 16;

/// Interns string literals into module globals so equal literals share one
/// copy of their bytes.
pub const LiteralPool = struct {
    gpa: Allocator,
    ctx: *api.Context,
    globals: std.StringHashMapUnmanaged(api.GlobalIdx),

    pub fn init(gpa: Allocator, ctx: *api.Context) LiteralPool {
        return .{
            .gpa = gpa,
            .ctx = ctx,
            .globals = .empty,
        };
    }

    pub fn deinit(self: *LiteralPool) void {
        var it = self.globals.keyIterator();
        while (it.next()) |key| {
            self.gpa.free(key.*);
        }
        self.globals.deinit(self.gpa);
    }

    /// Return (creating if needed) the global holding the NUL-terminated
    /// bytes of `bytes`. The pool owns a copy of the key.
    pub fn globalFor(self: *LiteralPool, bytes: []const u8) !api.GlobalIdx {
        if (self.globals.get(bytes)) |g| return g;
        const name = try std.fmt.allocPrint(self.gpa, "str_{d}", .{self.globals.count()});
        defer self.gpa.free(name);
        const owned = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned);
        const g = try self.ctx.addStringGlobal(name, bytes);
        try self.globals.put(self.gpa, owned, g);
        return g;
    }
};

/// Decode a string token body (raw source slice between the quotes, escapes
/// unprocessed) into the literal bytes.
pub fn unescape(gpa: Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);

    var i: usize = 0;
    while (i < raw.len) {
        const ch = raw[i];
        if (ch != '\\' or i + 1 >= raw.len) {
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        const esc = raw[i + 1];
        const decoded: u8 = switch (esc) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            '\\' => '\\',
            '"' => '"',
            '\'' => '\'',
            else => blk: {
                // Unknown escape: keep both characters verbatim.
                try out.append(gpa, '\\');
                break :blk esc;
            },
        };
        try out.append(gpa, decoded);
        i += 2;
    }

    return out.toOwnedSlice(gpa);
}

test "unescape: common escapes" {
    const a = std.testing.allocator;
    const bytes = try unescape(a, "a\\nb\\t\\\\\\\"");
    defer a.free(bytes);
    try std.testing.expectEqualStrings("a\nb\t\\\"", bytes);
}

test "unescape: empty and plain strings" {
    const a = std.testing.allocator;
    const empty = try unescape(a, "");
    defer a.free(empty);
    try std.testing.expectEqualSlices(u8, "", empty);

    const plain = try unescape(a, "hello world");
    defer a.free(plain);
    try std.testing.expectEqualStrings("hello world", plain);
}
