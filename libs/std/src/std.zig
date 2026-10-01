//! The Wolframite runtime library.
//!
//! This is what a compiled program links against. Every entry point here is
//! `export`ed with the platform's native C ABI, which is exactly the shape the
//! compiler's `extern_call` opcode expects — the lowerer names the symbol and
//! pushes arguments, there is no dynamic dispatch or bookkeeping in between.
//!
//! Symbol names are `wfr_std_<name>`. The compiler owns the mapping from a
//! Wolframite name to one of these, so renaming anything here is a breaking
//! change in `compiler/prelude.zig`.
//!
//! There is no libc here. Output goes to the kernel directly, and the only
//! allocation the runtime ever does is none: every entry point either takes
//! caller-owned memory or uses a fixed-size stack buffer.
//!
//! Conventions:
//!   - `void` really returns void.
//!   - Fallible entry points return `i64` — a nonnegative byte count, or `-1`
//!     when the OS refused the transfer.
//!   - Predicates return `i32`, `1` for true and `0` for false, because there
//!     is no portable zero-cost `bool` in an extern signature.

const std = @import("std");
const builtin = @import("builtin");

const abi = @import("abi.zig");
const fmt = @import("fmt.zig");
const os = @import("os.zig");

pub const String = abi.String;

/// `print(value: String)` — the one function the prelude injects into every
/// program. Writes `value` followed by a newline to stdout.
///
/// This is the ADR-0001 contract: the compiler emits a direct call to
/// `wfr_std_print` for the prelude name `print`, with no import statement and
/// no module resolution step.
export fn wfr_std_print(s: *const String) void {
    const bytes = bytesOf(s);
    _ = os.writeAll(os.stdoutHandle(), bytes);
    _ = os.writeAll(os.stdoutHandle(), "\n");
}

/// Write raw bytes to stdout with no trailing newline and no formatting.
export fn wfr_std_write_bytes(ptr: [*]const u8, len: usize) void {
    _ = os.writeAll(os.stdoutHandle(), ptr[0..len]);
}

/// Write `s` to stdout with no trailing newline.
export fn wfr_std_write_string(s: *const String) void {
    const bytes = bytesOf(s);
    _ = os.writeAll(os.stdoutHandle(), bytes);
}

/// Write a decimal integer and a newline to stdout.
export fn wfr_std_print_i64(value: i64) void {
    var buf: [fmt.i64_max_len + 1]u8 = undefined;
    const digits = fmt.decimalI64(buf[0..fmt.i64_max_len], value);
    _ = os.writeAll(os.stdoutHandle(), digits);
    _ = os.writeAll(os.stdoutHandle(), "\n");
}

/// Write a decimal integer and a newline to stdout.
export fn wfr_std_print_u64(value: u64) void {
    var buf: [fmt.u64_max_len + 1]u8 = undefined;
    const digits = fmt.decimalU64(buf[0..fmt.u64_max_len], value);
    _ = os.writeAll(os.stdoutHandle(), digits);
    _ = os.writeAll(os.stdoutHandle(), "\n");
}

/// Write a decimal float and a newline to stdout.
export fn wfr_std_print_f64(value: f64) void {
    var buf: [64]u8 = undefined;
    const digits = fmt.decimalF64(&buf, value);
    _ = os.writeAll(os.stdoutHandle(), digits);
    _ = os.writeAll(os.stdoutHandle(), "\n");
}

/// Write a `0x`-prefixed hexadecimal integer and a newline to stdout.
export fn wfr_std_print_hex(value: u64) void {
    var buf: [2 + fmt.u64_max_len + 1]u8 = undefined;
    const digits = fmt.hexU64(buf[0 .. 2 + fmt.u64_max_len], value);
    _ = os.writeAll(os.stdoutHandle(), digits);
    _ = os.writeAll(os.stdoutHandle(), "\n");
}

/// Write `len` bytes to a file descriptor. Returns bytes written or `-1`.
///
/// `fd` is a Windows handle or a POSIX descriptor, matching `Handle`.
export fn wfr_std_write(fd: i64, ptr: [*]const u8, len: usize) i64 {
    const done = os.writeAll(handleFrom(fd), ptr[0..len]);
    if (done != len) return -1;
    return @intCast(done);
}

/// Read up to `len` bytes from a file descriptor into `ptr`.
///
/// Returns the byte count, `0` at end of input, or `-1` on error.
export fn wfr_std_read(fd: i64, ptr: [*]u8, len: usize) i64 {
    const got = os.readSome(handleFrom(fd), ptr[0..len]);
    if (got == os.read_error) return -1;
    return @intCast(got);
}

/// Flush is a no-op: this runtime never buffers across entry points.
export fn wfr_std_flush() void {}

/// End the process with `code` as its exit status.
export fn wfr_std_exit(code: i32) noreturn {
    os.exit(code);
}

/// The length of a `String` header, as seen from inside a program.
export fn wfr_std_string_len(s: *const String) i64 {
    return s.len;
}

/// Compare two `String` headers by their bytes. Returns `1` or `0`.
export fn wfr_std_string_eq(a: *const String, b: *const String) i32 {
    const left = bytesOf(a);
    const right = bytesOf(b);
    if (left.len != right.len) return 0;
    return if (std.mem.eql(u8, left, right)) 1 else 0;
}

/// Write a runtime panic message to stderr and terminate with status `1`.
///
/// This is the only failure path the runtime owns. It cannot return, and it
/// never allocates, so it stays usable from anywhere — including a panic
/// raised while the program is already unwinding nothing.
export fn wfr_std_panic(s: *const String) noreturn {
    const bytes = bytesOf(s);
    _ = os.writeAll(os.stderrHandle(), "panic: ");
    _ = os.writeAll(os.stderrHandle(), bytes);
    _ = os.writeAll(os.stderrHandle(), "\n");
    os.exit(1);
}

/// Copy `len` bytes from `src` into `dst` and return the count, or `-1`.
///
/// The non-overlapping case is all the runtime promises; nothing here checks
/// for overlap because no internal caller can produce it.
export fn wfr_std_memcpy(dst: [*]u8, src: [*]const u8, len: usize) i64 {
    if (len == 0) return 0;
    std.mem.copyForwards(u8, dst[0..len], src[0..len]);
    return @intCast(len);
}

fn bytesOf(s: *const String) []const u8 {
    return abi.bytesOf(s);
}

/// Reinterpret a program-visible integer as an OS handle. A value the OS does
/// not recognise fails in the syscall rather than here, which keeps this free
/// of validation logic.
fn handleFrom(fd: i64) os.Handle {
    return switch (builtin.os.tag) {
        .windows => @ptrFromInt(@as(usize, @bitCast(fd))),
        .linux => @intCast(fd),
        else => unreachable,
    };
}

const testing = std.testing;

test "string_len reads the header field programs rely on" {
    const s = abi.stringFrom("abc");
    try testing.expectEqual(@as(i64, 3), wfr_std_string_len(&s));
}

test "string_eq compares bytes, not header addresses" {
    const a = abi.stringFrom("same");
    const b = abi.stringFrom("same");
    const c = abi.stringFrom("other");
    try testing.expectEqual(@as(i32, 1), wfr_std_string_eq(&a, &b));
    try testing.expectEqual(@as(i32, 0), wfr_std_string_eq(&a, &c));

    const empty_a = abi.stringFrom("");
    const empty_b = abi.stringFrom("");
    try testing.expectEqual(@as(i32, 1), wfr_std_string_eq(&empty_a, &empty_b));
}

test "string_eq treats equal content of differing capacity as equal" {
    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    @memcpy(first[0..5], "hello");
    @memcpy(second[0..5], "hello");
    const a = String{ .len = 5, .data = &first };
    const b = String{ .len = 5, .data = &second };
    try testing.expectEqual(@as(i32, 1), wfr_std_string_eq(&a, &b));
}

test "write and read report failure on a bad descriptor" {
    var scratch: [4]u8 = undefined;
    try testing.expectEqual(@as(i64, -1), wfr_std_write(-1, &scratch, 4));
    try testing.expectEqual(@as(i64, -1), wfr_std_read(-1, &scratch, 4));
}

test "write reports failure on a bad descriptor only when short" {
    var scratch: [4]u8 = undefined;
    try testing.expectEqual(@as(i64, 0), wfr_std_write(-1, &scratch, 0));
}

test "memcpy copies and reports the count" {
    var dst: [5]u8 = undefined;
    const src = "wfr!";
    try testing.expectEqual(@as(i64, 5), wfr_std_memcpy(&dst, src, 5));
    try testing.expectEqualStrings("wfr!\x00", &dst);
    try testing.expectEqual(@as(i64, 0), wfr_std_memcpy(&dst, src, 0));
}

test "integer formatting goes through the runtime, not std.fmt" {
    var buf: [fmt.i64_max_len]u8 = undefined;
    try testing.expectEqualStrings("-1", fmt.decimalI64(&buf, -1));
}
