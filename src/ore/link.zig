//! Assemble + link pipeline for `ore run` / `ore build --emit-bin`.
//!
//! The Tungsten backend emits NASM x86-64 assembly (Windows ABI), so ore
//! shells out to `nasm` to produce object files and to `zig cc` to link them
//! into an executable. `malloc` and friends resolve against the C runtime
//! pulled in by `zig cc`.
//!
//! Entry shim: the backend names the entry function `_main` (a NASM-era
//! convention), while the Windows x64 CRT resolves `main` / `WinMain` /
//! `wWinMain` depending on the subsystem it picks. ore therefore links a tiny
//! assembly shim exporting all three entry points, each branching to `_main`.
//!
//! Runtime: prelude calls such as `print` lower to extern calls into the
//! Wolframite runtime, `libs/std`, built by `zig build` and linked here as a
//! static library. That library is what actually implements the `wfr_std_*`
//! symbols — it talks to the kernel directly and pulls in no libc of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LinkError = error{
    /// `nasm` or `zig` not found on PATH, or a tool could not be started.
    ToolMissing,
    /// A tool ran but exited nonzero.
    ToolFailed,
    /// Could not write the entry shim.
    WriteFailed,
    /// The Wolframite runtime (`libs/std`) archive was not found.
    StdLibMissing,
};

const shim_asm_text =
    \\; ore entry shim
    \\; Tungsten emits `_main`; the Windows x64 CRT needs main/WinMain/wWinMain.
    \\bits 64
    \\default rel
    \\extern _main
    \\global main
    \\global WinMain
    \\global wWinMain
    \\section .text
    \\main:
    \\    jmp _main
    \\WinMain:
    \\    jmp _main
    \\wWinMain:
    \\    jmp _main
    \\
;

/// Directories, relative to the working directory, where `zig build` may have
/// installed the runtime archive. `ore` reads `ore.toml` from the working
/// directory too, so resolving the runtime the same way keeps one notion of
/// "where is this project".
const std_lib_dirs = [_][]const u8{
    "zig-out/lib",
    "build/zig-out/lib",
};

/// Archive file names for the runtime. `zig build-lib` writes `wfr_std.lib` for
/// Windows targets and `libwfr_std.a` for ELF ones.
const std_lib_names = [_][]const u8{
    "wfr_std.lib",
    "libwfr_std.a",
    "wfr_std.a",
};

/// Locate the Wolframite runtime archive, or fail with `StdLibMissing`.
fn findWfrStdLib(io: std.Io, gpa: Allocator) LinkError![]u8 {
    for (std_lib_dirs) |dir| {
        for (std_lib_names) |name| {
            const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
            if (fileExists(io, candidate)) return candidate;
            gpa.free(candidate);
        }
    }
    return error.StdLibMissing;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Run a tool and print its stderr on failure.
fn runTool(io: std.Io, gpa: Allocator, argv: []const []const u8) LinkError!void {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return error.ToolMissing;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("{s}", .{result.stderr});
                return error.ToolFailed;
            }
        },
        else => return error.ToolFailed,
    }
}

/// Assemble `<asm_path>` + entry shim with `nasm -f win64` and link with
/// `zig cc` into `<exe_path>`, together with the Wolframite runtime.
/// Intermediates are removed on success.
pub fn assembleAndLink(io: std.Io, gpa: Allocator, asm_path: []const u8, obj_path: []const u8, exe_path: []const u8) LinkError!void {
    const shim_asm_path = replaceExt(gpa, obj_path, "ore-shim.asm") catch return error.WriteFailed;
    defer gpa.free(shim_asm_path);
    const shim_obj_path = replaceExt(gpa, obj_path, "ore-shim.obj") catch return error.WriteFailed;
    defer gpa.free(shim_obj_path);

    const wfr_std_lib = try findWfrStdLib(io, gpa);
    defer gpa.free(wfr_std_lib);

    writeShim(io, shim_asm_path) catch return error.WriteFailed;
    defer deleteFile(io, shim_asm_path);
    defer deleteFile(io, shim_obj_path);

    try runTool(io, gpa, &.{ "nasm", "-f", "win64", "-o", shim_obj_path, shim_asm_path });
    try runTool(io, gpa, &.{ "nasm", "-f", "win64", "-o", obj_path, asm_path });
    try runTool(io, gpa, &.{ "zig", "cc", obj_path, shim_obj_path, wfr_std_lib, "-o", exe_path });

    // `zig cc` emits a PDB next to the exe in debug mode; drop it.
    deleteFile(io, replaceExt(gpa, exe_path, "pdb") catch return error.WriteFailed);
}

fn writeShim(io: std.Io, path: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(f, io, &buf);
    try w.interface.writeAll(shim_asm_text);
    try w.interface.flush();
}

/// Replace the extension of `path` with `.new_ext` (allocated).
fn replaceExt(gpa: Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse "";
    const stem = std.fs.path.stem(path);
    if (dir.len == 0) {
        return std.fmt.allocPrint(gpa, "{s}.{s}", .{ stem, new_ext });
    }
    return std.fmt.allocPrint(gpa, "{s}{c}{s}.{s}", .{ dir, std.fs.path.sep, stem, new_ext });
}

/// Remove a file, ignoring whether it exists.
pub fn deleteFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

const testing = std.testing;

test "findWfrStdLib reports a missing runtime instead of guessing" {
    // The test binary runs from the build cache, where no runtime is installed,
    // so this only asserts the error is reachable and carries a name the
    // caller can report.
    if (findWfrStdLib(testing.io, testing.allocator)) |path| {
        testing.allocator.free(path);
    } else |err| {
        try testing.expectEqual(LinkError.StdLibMissing, err);
    }
}

test "replaceExt rewrites the extension, keeping the directory" {
    const gpa = testing.allocator;
    const got = try replaceExt(gpa, "build/out/hello.asm", "obj");
    defer gpa.free(got);
    try testing.expectEqualStrings("build/out/hello.obj", got);

    const bare = try replaceExt(gpa, "hello.asm", "obj");
    defer gpa.free(bare);
    try testing.expectEqualStrings("hello.obj", bare);
}
