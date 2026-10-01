//! The ABI shared between the Wolframite compiler and this runtime.
//!
//! Everything here is layout, not behavior: the compiler writes these bytes and
//! this library reads them back. The definitions must stay in lockstep with
//! `compiler/codegen/string.zig` (the `String` header the lowerer emits) and
//! with `compiler/prelude.zig` (the prelude signatures).
//!
//! Calling convention is the platform's native C ABI (Win64 / SysV) — a
//! Wolframite `fn` lowered to an `extern_call` passes its arguments exactly
//! like a C function, so the runtime sees ordinary values.

/// A Wolframite `String` header. A `String` value in a program is a *pointer*
/// to one of these 16-byte blocks:
///
/// ```text
/// [ len: i64 ][ data: u8* ]
/// ```
///
/// The block itself is stack allocated by the lowerer; `data` points at
/// NUL-terminated bytes in the module's `.data` section for a literal. `len` is
/// authoritative — `data` is *not* NUL-terminated as far as a program is
/// concerned, so every entry point here writes exactly `len` bytes.
pub const String = extern struct {
    len: i64,
    data: [*]const u8,
};

/// Byte offsets inside `String`, mirrored from `compiler/codegen/string.zig`.
pub const string_len_offset: u64 = 0;
pub const string_data_offset: u64 = 8;
pub const string_size: u32 = 16;

/// Build a `String` header over `bytes` (borrowed, not copied).
pub fn stringFrom(bytes: []const u8) String {
    return .{ .len = @intCast(bytes.len), .data = bytes.ptr };
}

/// The borrowed byte view of a `String`, as the runtime sees it.
///
/// A `len` that is negative or beyond the address space is a malformed header
/// from miscompiled code, not a runtime error we can recover from; it is
/// clamped to zero here so a bad header cannot turn into a wild read.
pub fn bytesOf(s: *const String) []const u8 {
    if (s.len <= 0) return s.data[0..0];
    return s.data[0..@intCast(s.len)];
}

/// Read the `len` field of a `String` header by pointer arithmetic, the way
/// the runtime would read it off a foreign frame. Used by the tests that pin
/// the header offsets.
pub fn lenAt(header: [*]const u8) i64 {
    const raw: *const i64 = @ptrCast(@alignCast(header + string_len_offset));
    return raw.*;
}

/// Read the `data` field of a `String` header by pointer arithmetic.
pub fn dataAt(header: [*]const u8) [*]const u8 {
    const raw: [*]const [*]const u8 = @ptrCast(@alignCast(header + string_data_offset));
    return raw[0];
}

const std = @import("std");
const testing = std.testing;

test "String header is 16 bytes: len at 0, data at 8" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(String));
    try testing.expectEqual(@as(u64, 0), string_len_offset);
    try testing.expectEqual(@as(u64, 8), string_data_offset);

    var buf: [32]u8 = undefined;
    const bytes = "Hello, world!";
    @memcpy(buf[0..bytes.len], bytes);

    const header = String{ .len = @intCast(bytes.len), .data = &buf };
    try testing.expectEqual(@as(i64, 13), lenAt(@ptrCast(&header)));
    try testing.expectEqualStrings(bytes, bytesOf(&header)[0..13]);

    // The pointer fields must be readable at the documented offsets, since
    // that is exactly what a NASM-emitted call site hands us.
    try testing.expectEqual(@as(i64, 13), lenAt(@ptrCast(&header)));
    try testing.expectEqualStrings("Hello", std.mem.sliceTo(dataAt(@ptrCast(&header)), 0)[0..5]);
}

test "bytesOf tolerates a malformed length" {
    const empty = String{ .len = 0, .data = undefined };
    try testing.expectEqual(@as(usize, 0), bytesOf(&empty).len);

    const negative = String{ .len = -5, .data = undefined };
    try testing.expectEqual(@as(usize, 0), bytesOf(&negative).len);
}

test "stringFrom borrows without copying" {
    var buf: [4]u8 = undefined;
    @memcpy(buf[0..4], "abcd");
    const s = stringFrom(&buf);
    try testing.expectEqual(@as(i64, 4), s.len);
    try testing.expectEqual(@intFromPtr(&buf), @intFromPtr(s.data));
    buf[0] = 'z';
    try testing.expectEqual(@as(u8, 'z'), bytesOf(&s)[0]);
}
