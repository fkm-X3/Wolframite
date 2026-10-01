//! Decimal formatting, written out by hand so the runtime never depends on a
//! formatter for the integer cases — those are the ones programs hit on every
//! loop iteration.
//!
//! Every function writes into a caller-provided buffer and returns the
//! initialized slice of it. `buf` is never grown and nothing is allocated:
//! formatting a number must not be able to fail, because the failure paths out
//! of a formatter are exactly the paths a runtime should not have.

const std = @import("std");

/// Longest decimal form of a 64-bit signed integer, including `-` and sign.
pub const i64_max_len: usize = 20;
/// Longest decimal form of a 64-bit unsigned integer.
pub const u64_max_len: usize = 20;

/// Write `value` in base 10 into `buf`, returning the digits written.
///
/// Negative values get a leading `-`. Trailing behavior matches the rest of
/// the runtime: `len` is authoritative and the bytes are never NUL-terminated.
pub fn decimalI64(buf: []u8, value: i64) []const u8 {
    // Negate through the bit pattern: `0 - minInt(i64)` overflows, and
    // `~value +% 1` overflows too when it is done in signed arithmetic.
    const magnitude: u64 = if (value < 0) @as(u64, @bitCast(~value)) +% 1 else @intCast(value);

    var digits: [u64_max_len]u8 = undefined;
    var index: usize = digits.len;
    index = writeDigits(digits[0..index], magnitude, 10);

    if (value < 0 and index > 0) {
        index -= 1;
        digits[index] = '-';
    }
    return copyOut(buf, digits[index..]);
}

/// Write `value` in base 10 into `buf`, returning the digits written.
pub fn decimalU64(buf: []u8, value: u64) []const u8 {
    var digits: [u64_max_len]u8 = undefined;
    const index = writeDigits(digits[0..], value, 10);
    return copyOut(buf, digits[index..]);
}

/// Write `value` in base 16 with a `0x` prefix into `buf`.
///
/// If `buf` is too small, the prefix still comes first and the least
/// significant digits are the ones kept — a truncated hex dump should still
/// tell you what the low bits were.
pub fn hexU64(buf: []u8, value: u64) []const u8 {
    var scratch: [u64_max_len]u8 = undefined;
    const digits = scratch[writeDigits(&scratch, value, 16)..];

    var filled: usize = 0;
    if (buf.len >= 2) {
        buf[0] = '0';
        buf[1] = 'x';
        filled = 2;
    }
    const take = @min(buf.len - filled, digits.len);
    @memcpy(buf[filled..][0..take], digits[digits.len - take ..]);
    return buf[0 .. filled + take];
}

/// Write `value` as decimal into `buf`, returning the text produced.
///
/// Floats go through the compiler's own formatter, so the shape of the output
/// is Zig's `{d}`: `1` for `1.0`, `1.5e1` for `15`. Non-finite input renders as
/// `nan`, `inf`, and `-inf` rather than trapping.
pub fn decimalF64(buf: []u8, value: f64) []const u8 {
    if (std.math.isNan(value)) return copyOut(buf, "nan");
    if (std.math.isPositiveInf(value)) return copyOut(buf, "inf");
    if (std.math.isNegativeInf(value)) return copyOut(buf, "-inf");

    var writer: std.Io.Writer = .fixed(buf);
    writer.print("{d}", .{value}) catch return buf[0..0];
    return buf[0..writer.end];
}

/// Fill `scratch` from the right with `value` in `base`, returning the index
/// the digits start at.
fn writeDigits(scratch: []u8, value: u64, comptime base: u64) usize {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var index: usize = scratch.len;
    var rest = value;
    while (true) {
        index -= 1;
        scratch[index] = digits[@intCast(rest % base)];
        rest /= base;
        if (rest == 0) break;
    }
    return index;
}

fn copyOut(buf: []u8, src: []const u8) []const u8 {
    const n = @min(buf.len, src.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

const testing = std.testing;

test "decimalI64 renders zero, sign, and boundaries" {
    var buf: [i64_max_len]u8 = undefined;

    try testing.expectEqualStrings("0", decimalI64(&buf, 0));
    try testing.expectEqualStrings("7", decimalI64(&buf, 7));
    try testing.expectEqualStrings("42", decimalI64(&buf, 42));
    try testing.expectEqualStrings("-42", decimalI64(&buf, -42));
    try testing.expectEqualStrings("9223372036854775807", decimalI64(&buf, std.math.maxInt(i64)));
    try testing.expectEqualStrings("-9223372036854775808", decimalI64(&buf, std.math.minInt(i64)));
}

test "decimalU64 renders the full unsigned range" {
    var buf: [u64_max_len]u8 = undefined;

    try testing.expectEqualStrings("0", decimalU64(&buf, 0));
    try testing.expectEqualStrings("18446744073709551615", decimalU64(&buf, std.math.maxInt(u64)));
    try testing.expectEqualStrings("1000000000000000000", decimalU64(&buf, 1000000000000000000));
}

test "decimalI64 agrees with the standard library" {
    var mine: [i64_max_len]u8 = undefined;
    var theirs: [i64_max_len]u8 = undefined;
    var probe: i64 = -1000;
    while (probe < 1000) : (probe += 7) {
        var writer: std.Io.Writer = .fixed(&theirs);
        try writer.print("{d}", .{probe});
        try testing.expectEqualStrings(theirs[0..writer.end], decimalI64(&mine, probe));
    }
}

test "hexU64 pads with a prefix and no leading zeros" {
    var buf: [2 + u64_max_len]u8 = undefined;

    try testing.expectEqualStrings("0x0", hexU64(&buf, 0));
    try testing.expectEqualStrings("0xff", hexU64(&buf, 255));
    try testing.expectEqualStrings("0xdeadbeef", hexU64(&buf, 0xDEADBEEF));
    try testing.expectEqualStrings("0xffffffffffffffff", hexU64(&buf, std.math.maxInt(u64)));
}

test "decimalF64 renders the documented shapes" {
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("1", decimalF64(&buf, 1.0));
    try testing.expectEqualStrings("0", decimalF64(&buf, 0.0));
    try testing.expectEqualStrings("1.5", decimalF64(&buf, 1.5));
    try testing.expectEqualStrings("-2.25", decimalF64(&buf, -2.25));
    try testing.expectEqualStrings("nan", decimalF64(&buf, std.math.nan(f64)));
    try testing.expectEqualStrings("inf", decimalF64(&buf, std.math.inf(f64)));
    try testing.expectEqualStrings("-inf", decimalF64(&buf, -std.math.inf(f64)));
}

test "a short buffer truncates instead of overflowing" {
    var buf: [4]u8 = undefined;

    try testing.expectEqualStrings("1234", decimalU64(buf[0..4], 123456789));
    try testing.expectEqualStrings("12", decimalU64(buf[0..2], 123456789));
    try testing.expectEqualStrings("", decimalU64(buf[0..0], 123456789));
}

test "a short hex buffer keeps the prefix and the low digits" {
    var buf: [5]u8 = undefined;

    try testing.expectEqualStrings("0xff", hexU64(buf[0..4], 255));
    try testing.expectEqualStrings("0xeef", hexU64(&buf, 0xDEADBEEF));
    try testing.expectEqualStrings("0x0", hexU64(buf[0..3], 0));
    try testing.expectEqualStrings("", hexU64(buf[0..0], 0xDEADBEEF));
    try testing.expectEqualStrings("f", hexU64(buf[0..1], 0xDEADBEEF));
}
