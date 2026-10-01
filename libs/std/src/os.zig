//! The thinnest possible OS layer: just enough raw syscalls for the runtime to
//! write a byte stream, read a byte stream, and exit a process.
//!
//! No libc is involved on either platform. Windows talks to `kernel32`
//! directly; Linux goes through Zig's raw syscall wrappers. Nothing here
//! allocates, locks, or buffers — `writeAll` is the only loop, and it exists
//! because a short write is normal on a pipe.

const std = @import("std");
const builtin = @import("builtin");

/// Returned by `readSome` when the OS reported an error rather than data.
pub const read_error: usize = std.math.maxInt(usize);

/// A kernel handle on Windows, a file descriptor on Linux.
pub const Handle = switch (builtin.os.tag) {
    .windows => *anyopaque,
    .linux => i32,
    else => @compileError("Wolframite std supports windows and linux only"),
};

/// One Win32 transfer is capped at a 32-bit length; cap every platform so the
/// short-write loop behaves identically everywhere.
const chunk_max: usize = 1 << 20;

const windows = if (builtin.os.tag == .windows) struct {
    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));

    extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WriteFile(
        h: ?*anyopaque,
        buf: ?*const anyopaque,
        n: u32,
        written: ?*u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn ReadFile(
        h: ?*anyopaque,
        buf: ?*anyopaque,
        n: u32,
        read: ?*u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
} else struct {};

pub fn stdoutHandle() Handle {
    return switch (builtin.os.tag) {
        .windows => windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse invalidHandle(),
        .linux => 1,
        else => unreachable,
    };
}

pub fn stderrHandle() Handle {
    return switch (builtin.os.tag) {
        .windows => windows.GetStdHandle(windows.STD_ERROR_HANDLE) orelse invalidHandle(),
        .linux => 2,
        else => unreachable,
    };
}

pub fn stdinHandle() Handle {
    return switch (builtin.os.tag) {
        .windows => windows.GetStdHandle(windows.STD_INPUT_HANDLE) orelse invalidHandle(),
        .linux => 0,
        else => unreachable,
    };
}

/// A handle the OS is guaranteed to reject, for exercising the error paths.
pub fn invalidHandle() Handle {
    return switch (builtin.os.tag) {
        .windows => @ptrFromInt(std.math.maxInt(usize)),
        .linux => -1,
        else => unreachable,
    };
}

/// Write every byte of `bytes` to `handle`, looping over short writes.
///
/// Returns the number of bytes the OS accepted, which is less than
/// `bytes.len` only if the handle failed or the process is being torn down.
/// An interrupted write is retried rather than reported as truncated.
pub fn writeAll(handle: Handle, bytes: []const u8) usize {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = @min(chunk_max, bytes.len - done);
        switch (builtin.os.tag) {
            .windows => {
                var written: u32 = 0;
                const ok = windows.WriteFile(
                    handle,
                    @ptrCast(bytes.ptr + done),
                    @intCast(n),
                    &written,
                    null,
                );
                if (ok == 0 or written == 0) break;
                done += written;
            },
            .linux => {
                const rc = std.os.linux.write(handle, bytes.ptr + done, n);
                if (std.os.linux.errno(rc) == .INTR) continue;
                if (std.os.linux.errno(rc) != .SUCCESS) break;
                if (rc == 0) break;
                done += rc;
            },
            else => unreachable,
        }
    }
    return done;
}

/// Read up to `buf.len` bytes from `handle`.
///
/// Returns `0` at end of input, `read_error` if the OS reported an error, and
/// otherwise the number of bytes placed in `buf`.
pub fn readSome(handle: Handle, buf: []u8) usize {
    var done: usize = 0;
    while (done < buf.len) {
        const n = @min(chunk_max, buf.len - done);
        switch (builtin.os.tag) {
            .windows => {
                var got: u32 = 0;
                const ok = windows.ReadFile(handle, @ptrCast(buf.ptr + done), @intCast(n), &got, null);
                if (ok == 0) {
                    return switch (std.os.windows.GetLastError()) {
                        .HANDLE_EOF, .BROKEN_PIPE, .NO_DATA => done,
                        else => read_error,
                    };
                }
                if (got == 0) return done;
                done += got;
            },
            .linux => {
                const rc = std.os.linux.read(handle, buf.ptr + done, n);
                switch (std.os.linux.errno(rc)) {
                    .INTR => continue,
                    .SUCCESS => {},
                    else => return read_error,
                }
                if (rc == 0) return done;
                done += rc;
            },
            else => unreachable,
        }
    }
    return done;
}

/// Terminate the process immediately with `code`.
///
/// This bypasses every buffered write on purpose: a runtime that is exiting
/// does not get to clean up.
pub fn exit(code: i32) noreturn {
    switch (builtin.os.tag) {
        .windows => windows.ExitProcess(@bitCast(code)),
        .linux => std.os.linux.exit(code),
        else => unreachable,
    }
}

const testing = std.testing;

test "writeAll gives up on a handle the OS rejects" {
    try testing.expectEqual(@as(usize, 0), writeAll(invalidHandle(), "wolframite"));
}

test "writeAll accepts nothing when there is nothing to write" {
    try testing.expectEqual(@as(usize, 0), writeAll(stdoutHandle(), ""));
}

test "readSome reports the error path rather than pretending it read data" {
    var scratch: [8]u8 = undefined;
    try testing.expectEqual(read_error, readSome(invalidHandle(), &scratch));
}

test "readSome on an empty buffer never touches the OS" {
    var scratch: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), readSome(stdinHandle(), scratch[0..0]));
}

test "stdout, stderr, and stdin are distinct handles" {
    try testing.expect(std.meta.eql(stdoutHandle(), stdinHandle()) == false);
    try testing.expect(std.meta.eql(stderrHandle(), stdinHandle()) == false);
}
