//! Link pipeline for `ore run` / `ore build --emit-bin`.
//!
//! Ore now compiles the source to a relocatable object (via Tungsten's object
//! emission) and links it into an executable using Ferro — the Tungsten
//! backend's internal linker. Runtime: prelude calls such as `print` lower to
//! extern calls into the Wolframite runtime, `libs/std`, built by `zig build`
//! and linked here as a static object/archive. Ferro reads the runtime
//! alongside the program object and resolves `wfr_std_*` symbols against it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const ferro = @import("Tungsten").ferro;
const compile_mod = @import("compile.zig");

pub const LinkError = error{
    /// `wfr_std` could not be located on disk.
    StdLibMissing,
    /// The Wolframite compiler pipeline failed to emit an object.
    CompileFailed,
    /// Ferro failed to link the object into an executable.
    LinkFailed,
};

/// Directories, relative to the working directory, where `zig build` may have
/// installed the runtime archive. `ore` reads `ore.toml` from the working
/// directory too, so resolving the runtime the same way keeps one notion of
/// "where is this project".
const std_lib_dirs = [_][]const u8{
    "zig-out/lib",
    "build/zig-out/lib",
};

/// Archive/file names for the runtime, per platform.
const std_lib_names = [_][]const u8{
    "wfr_std.lib",
    "libwfr_std.a",
    "wfr_std.a",
};

/// Locate the Wolframite runtime object/archive, or fail with `StdLibMissing`.
///
/// `ore` first tries the project-local `zig-out/` layout (where `zig build`
/// installs the runtime), then falls back to the system-wide install location
/// used when `ore` is installed outside the repository (`/usr/local/wolframite`
/// on Linux, `%USERPROFILE%\wolframite` on Windows). The install location is
/// resolved two ways:
///
///   From the running `ore` executable: `<exedir>/../lib` (the install
///      scripts mirror the zig-out/ layout, i.e. `<install>/bin/ore` and
///      `<install>/lib/wfr_std.lib`).
///   The POSIX system path `/usr/local/wolframite/lib`.
fn findWfrStdLib(io: std.Io, gpa: Allocator) LinkError![]u8 {
    // Project-local layouts (zig-out/), tried first.
    for (std_lib_dirs) |dir| {
        for (std_lib_names) |name| {
            const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
            if (fileExists(io, candidate)) return candidate;
            gpa.free(candidate);
        }
    }

    // Install location derived from the running `ore` executable:
    //    <exedir>/../lib. Mirrors the zig-out/ layout used by install scripts.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch 0;
    if (exe_len > 0) {
        const exe_path = exe_buf[0..exe_len];
        if (fileExists(io, exe_path)) {
            const bindir = std.fs.path.dirname(exe_path);
            if (bindir) |b| {
                const installdir = std.fs.path.dirname(b);
                if (installdir) |i| {
                    const lib_dir = std.fs.path.join(gpa, &.{ i, "lib" }) catch return error.StdLibMissing;
                    defer gpa.free(lib_dir);
                    for (std_lib_names) |name| {
                        const candidate = std.fs.path.join(gpa, &.{ lib_dir, name }) catch continue;
                        if (fileExists(io, candidate)) return candidate;
                        gpa.free(candidate);
                    }
                }
            }
        }
    }

    // POSIX system install location, e.g. /usr/local/wolframite/lib.
    const posix_install_dir: []const u8 = "/usr/local/wolframite/lib";
    if (std.fs.path.isAbsolute(posix_install_dir)) {
        for (std_lib_names) |name| {
            const candidate = std.fs.path.join(gpa, &.{ posix_install_dir, name }) catch continue;
            if (fileExists(io, candidate)) return candidate;
            gpa.free(candidate);
        }
    }

    return error.StdLibMissing;
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Replace the extension of `path` with `.new_ext` (allocated).
pub fn replaceExt(gpa: Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse "";
    const stem = std.fs.path.stem(path);
    if (dir.len == 0) {
        return std.fmt.allocPrint(gpa, "{s}.{s}", .{ stem, new_ext });
    }
    return std.fmt.allocPrint(gpa, "{s}{c}{s}.{s}", .{ dir, std.fs.path.sep, stem, new_ext });
}

/// Compile `source_path` to an object file at `obj_path` (via Tungsten object
/// emission) and link it with the Wolframite runtime into `exe_path` via Ferro.
///
/// The object file is written as an intermediate alongside the executable.
///
/// When `dump_image` is true, Ferro prints the merged image (section sizes,
/// symbol addresses, relocations before/after application) to stderr before
/// writing the executable — a debugging aid for linker issues.
pub fn linkBinary(
    io: std.Io,
    gpa: Allocator,
    source_path: []const u8,
    exe_path: []const u8,
    dump_image: bool,
) LinkError!void {
    const obj_path = replaceExt(gpa, exe_path, hostObjectExt()) catch return error.LinkFailed;
    defer gpa.free(obj_path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, source_path, gpa, .unlimited) catch return error.CompileFailed;
    defer gpa.free(source);

    const target = hostTarget();

    // All compiler allocations (AST, types, diagnostics, object bytes) are
    // owned by this arena and released when linking completes.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const result = compile_mod.compile(arena_alloc, source, .obj, target) catch return error.CompileFailed;
    if (!result.ok) return error.CompileFailed;

    const obj_bytes = result.text orelse return error.CompileFailed;
    const write_obj = std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = obj_path,
        .data = obj_bytes,
    }) catch return error.CompileFailed;

    _ = write_obj;

    const wfr_std_lib = try findWfrStdLib(io, gpa);
    defer gpa.free(wfr_std_lib);

    var opts = ferro.defaultLinkOptions(target);
    opts.dump = dump_image;
    if (ferro.linkObject(io, gpa, obj_path, wfr_std_lib, exe_path, opts)) |_| {} else |_| {
        return error.LinkFailed;
    }
}

/// The default object-file extension for the host OS: `.obj` on Windows, `.o`
/// elsewhere (mirrors Tungsten's object-format mapping).
pub fn hostObjectExt() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "obj",
        else => "o",
    };
}

/// The `ferro.Target` for the host OS ore is running on.
pub fn hostTarget() ferro.Target {
    return switch (builtin.os.tag) {
        .windows => .windows_x86_64,
        .linux => .linux_x86_64,
        else => .linux_x86_64,
    };
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

test "linkBinary reports CompileFailed for source that does not compile" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const source_path = "link_binary_compile_failed.wfr";
    const exe_path = "link_binary_compile_failed.exe";
    const obj_path = replaceExt(gpa, exe_path, hostObjectExt()) catch {
        return;
    };
    defer gpa.free(obj_path);
    defer {
        _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, exe_path) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, obj_path) catch {};
    }

    const bad_source = "fn main() -> i32 { return \n";
    if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = bad_source })) |_| {} else |_| {
        // The test working directory is not writable; nothing meaningful to assert.
        return;
    }

    if (linkBinary(io, gpa, source_path, exe_path, false)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.CompileFailed, err);
    }
}

test "linkBinary reports StdLibMissing when the runtime archive is absent" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const source_path = "link_binary_stdlib_missing.wfr";
    const exe_path = "link_binary_stdlib_missing.exe";
    const obj_path = replaceExt(gpa, exe_path, hostObjectExt()) catch {
        return;
    };
    defer gpa.free(obj_path);
    defer {
        _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, exe_path) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, obj_path) catch {};
    }

    const good_source = "fn main() -> i32 { return 0 }\n";
    if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = good_source })) |_| {} else |_| {
        return;
    }

    var runtime_absent: bool = true;
    if (findWfrStdLib(io, gpa)) |path| {
        gpa.free(path);
        runtime_absent = false;
    } else |_| {}

    if (linkBinary(io, gpa, source_path, exe_path, false)) |_| {
        // Only reachable when a runtime is installed in the test environment.
        try std.testing.expectEqual(false, runtime_absent);
        if (std.Io.Dir.cwd().statFile(io, exe_path, .{})) |_| {} else |_| {
            try std.testing.expect(false);
        }
    } else |err| {
        try std.testing.expectEqual(true, runtime_absent);
        try std.testing.expectEqual(LinkError.StdLibMissing, err);
    }
}

test "replaceExt rewrites the extension, keeping the directory" {
    const gpa = testing.allocator;
    const got = try replaceExt(gpa, "build/out/hello.obj", "o");
    defer gpa.free(got);
    const expected = try std.fmt.allocPrint(gpa, "build/out{c}hello.o", .{std.fs.path.sep});
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, got);

    const bare = try replaceExt(gpa, "hello.o", "obj");
    defer gpa.free(bare);
    try testing.expectEqualStrings("hello.obj", bare);
}
