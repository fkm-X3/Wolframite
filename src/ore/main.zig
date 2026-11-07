//! ore — the Wolframite package manager.
//!
//! Currently a single-file build tool wrapping the full compiler pipeline
//! (see `compile.zig`), with package scaffolding (`init`), a run mode that
//! assembles + links via Ferro (`run`, `build --emit-bin`),
//! and a self-update command that installs new ore releases (which bundle
//! the compiler) from GitHub (`update`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const ferro = @import("Tungsten").ferro;
const manifest_mod = @import("manifest.zig");
const compile_mod = @import("compile.zig");
const link_mod = @import("link.zig");
const update_mod = @import("update.zig");

const replaceExt = link_mod.replaceExt;
const hostObjectExt = link_mod.hostObjectExt;
const hostTarget = link_mod.hostTarget;

// Include link.zig's test blocks in the ore test build, mirroring the
// pattern used by compiler/root.zig so that imported modules' tests run.
test {
    _ = @import("link.zig");
}

const diag_mod = @import("compiler").diagnostics;

const version_string = "Dev (unstable)";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        printHelp(io);
        return;
    }

    const command = args[1];

    // Internal entrypoint used by the self-update helper process.
    if (std.mem.eql(u8, command, update_mod.apply_update_marker)) {
        std.process.exit(update_mod.applyUpdate(gpa, io, args[2..]) catch 1);
    }

    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        printHelp(io);
        return;
    }
    if (std.mem.eql(u8, command, "-V") or std.mem.eql(u8, command, "--version")) {
        printOut(io, "ore {s}\n", .{version_string});
        return;
    }

    const code = runCommand(gpa, io, command, args[2..]) catch |err| blk: {
        reportErr(io, "error: {s}\n", .{@errorName(err)});
        break :blk 1;
    };
    std.process.exit(code);
}

fn runCommand(gpa: Allocator, io: Io, command: []const u8, rest: []const []const u8) !u8 {
    if (std.mem.eql(u8, command, "init")) return cmdInit(gpa, io, rest);
    if (std.mem.eql(u8, command, "build")) return cmdBuild(gpa, io, rest);
    if (std.mem.eql(u8, command, "run")) return cmdRun(gpa, io, rest);
    if (std.mem.eql(u8, command, "update")) return cmdUpdate(gpa, io, rest);

    reportErr(io, "error: unknown command '{s}'\n", .{command});
    printHelp(io);
    return 2;
}

// ============================================================================
// init
// ============================================================================

fn cmdInit(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    if (args.len > 1) {
        reportErr(io, "usage: ore init [name]\n", .{});
        return 2;
    }

    if (std.Io.Dir.cwd().access(io, "ore.toml", .{})) |_| {
        reportErr(io, "error: ore.toml already exists in this directory\n", .{});
        return 1;
    } else |_| {}

    const name = if (args.len == 1) blk: {
        break :blk args[0];
    } else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
        const cwd = cwd_buf[0..n];
        break :blk std.fs.path.basename(cwd);
    };

    var manifest = manifest_mod.Manifest{ .name = name };
    const manifest_text = try manifest.render(gpa);

    const manifest_file = std.Io.Dir.cwd().createFile(io, "ore.toml", .{}) catch |err| {
        reportErr(io, "error: could not write ore.toml: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer manifest_file.close(io);
    writeFile(io, manifest_file, manifest_text) catch {
        reportErr(io, "error: could not write ore.toml\n", .{});
        return 1;
    };

    std.Io.Dir.cwd().createDirPath(io, "src") catch {};
    const main_file = std.Io.Dir.cwd().createFile(io, "src/main.wfr", .{}) catch |err| {
        reportErr(io, "error: could not write src/main.wfr: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer main_file.close(io);
    writeFile(io, main_file,
        \\fn main() -> i32 {
        \\    print("Hello, world!")
        \\    return 0
        \\}
        \\
    ) catch {
        reportErr(io, "error: could not write src/main.wfr\n", .{});
        return 1;
    };

    printOut(io, "initialized package '{s}' (entry: src/main.wfr)\n", .{name});
    printOut(io, "next: `ore run`\n", .{});
    return 0;
}

// ============================================================================
// build
// ============================================================================

fn cmdBuild(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var mode: compile_mod.EmitMode = .@"obj";
    var emit_bin = true;
    var file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printBuildHelp(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return flagNeedsValue(io, arg);
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--ir")) {
            mode = .ir;
            emit_bin = false;
        } else if (std.mem.eql(u8, arg, "--obj")) {
            mode = .@"obj";
            emit_bin = false;
        } else if (std.mem.eql(u8, arg, "--emit-bin")) {
            emit_bin = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            reportErr(io, "error: unknown option '{s}'\n", .{arg});
            return 2;
        } else if (file == null) {
            file = arg;
        } else {
            reportErr(io, "error: unexpected argument '{s}'\n", .{arg});
            return 2;
        }
    }

    if (emit_bin and mode == .ir) {
        reportErr(io, "error: --emit-bin cannot be combined with --ir\n", .{});
        return 2;
    }

    const source_path = (try resolveSource(gpa, io, file)) orelse return 2;

    if (emit_bin) {
        const exe_path = out_path orelse try replaceExt(gpa, source_path, "exe");
        link_mod.linkBinary(io, gpa, source_path, exe_path) catch |err| switch (err) {
            link_mod.LinkError.CompileFailed => {
                reportErr(io, "error: compilation failed\n", .{});
                return 1;
            },
            link_mod.LinkError.LinkFailed => {
                reportErr(io, "error: link failed\n", .{});
                return 1;
            },
            link_mod.LinkError.StdLibMissing => {
                reportErr(io, "error: could not find the Wolframite runtime archive 'wfr_std'\n", .{});
                reportErr(io, "       run 'zig build' from the repository root first\n", .{});
                return 1;
            },
        };
        printOut(io, "wrote {s}\n", .{exe_path});
        return 0;
    }

    const source = readSource(gpa, io, source_path) orelse return 1;

    const result = compile_mod.compile(gpa, source, mode, hostTarget()) catch |err| {
        reportErr(io, "error: {s}\n", .{@errorName(err)});
        return 1;
    };
    reportDiagnostics(io, source_path, &result.diagnostics);

    if (!result.ok) {
        reportErr(io, "error: compilation failed\n", .{});
        return 1;
    }

    switch (mode) {
        .none => unreachable,
        .ir => {
            const ir_path = out_path orelse try replaceExt(gpa, source_path, "ir");
            if ((try writeTextFile(io, ir_path, result.text.?)) != 0) return 1;
            printOut(io, "wrote {s}\n", .{ir_path});
            return 0;
        },
        .@"obj" => {
            const obj_path = out_path orelse try replaceExt(gpa, source_path, hostObjectExt());
            if ((try writeBinaryFile(io, obj_path, result.text.?)) != 0) return 1;
            printOut(io, "wrote {s}\n", .{obj_path});
            return 0;
        },
    }
}

// ============================================================================
// run
// ============================================================================

fn cmdRun(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var prog_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printRunHelp(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return flagNeedsValue(io, arg);
            i += 1;
            out_path = args[i];
        } else if (arg.len > 0 and arg[0] == '-' and file == null) {
            reportErr(io, "error: unknown option '{s}'\n", .{arg});
            return 2;
        } else if (file == null) {
            file = arg;
        } else {
            try prog_args.append(gpa, arg);
        }
    }

    const source_path = (try resolveSource(gpa, io, file)) orelse return 2;

    const exe_path = out_path orelse try replaceExt(gpa, source_path, "exe");

    // `ore run` only executes a binary already produced by `ore build`; it
    // never compiles or links.
    if (!link_mod.fileExists(io, exe_path)) {
        reportErr(io, "error: executable '{s}' not found\n", .{exe_path});
        reportErr(io, "       run `ore build` first\n", .{});
        return 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, exe_path);
    try argv.appendSlice(gpa, prog_args.items);
    const argv_slice = try argv.toOwnedSlice(gpa);

    var child = spawnOrShell(io, gpa, exe_path, argv_slice) catch |err| {
        reportErr(io, "error: could not start '{s}': {s}\n", .{ exe_path, @errorName(err) });
        return 1;
    };
    const term = child.wait(io) catch |err| {
        reportErr(io, "error: could not wait for '{s}': {s}\n", .{ exe_path, @errorName(err) });
        return 1;
    };

    switch (term) {
        .exited => |code| return code,
        else => {
            reportErr(io, "error: program terminated abnormally\n", .{});
            return 1;
        },
    }
}

/// Spawn `exe` directly, falling back to the OS shell when direct process
/// creation fails (e.g. Windows `InvalidExe` for a freshly linked executable).
///
/// On Windows this runs `cmd /c "<exe>" <args...>`; elsewhere `sh -c "<exe>" <args...>`.
fn spawnOrShell(
    io: Io,
    gpa: Allocator,
    exe_path: []const u8,
    args: []const []const u8,
) !std.process.Child {
    const child = std.process.spawn(io, .{
        .argv = args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        if (err != error.InvalidExe) return err;
        const shell_cmd = switch (builtin.os.tag) {
            .windows => "cmd",
            else => "sh",
        };
        const shell_arg = switch (builtin.os.tag) {
            .windows => "/c",
            else => "-c",
        };

        // Build the command string: "<exe>" <arg1> <arg2> ...
        var cmd_buf: std.ArrayList(u8) = .empty;
        try cmd_buf.appendSlice(gpa, exe_path);
        for (args[1..]) |arg| {
            try cmd_buf.append(gpa, ' ');
            try cmd_buf.appendSlice(gpa, arg);
        }
        const cmd_str = try cmd_buf.toOwnedSlice(gpa);

        var shell_args: std.ArrayList([]const u8) = .empty;
        try shell_args.append(gpa, shell_cmd);
        try shell_args.append(gpa, shell_arg);
        try shell_args.append(gpa, cmd_str);
        const shell_argv = try shell_args.toOwnedSlice(gpa);

        return std.process.spawn(io, .{
            .argv = shell_argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
    };
    return child;
}

// ============================================================================
// update
// ============================================================================

fn cmdUpdate(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var opts: update_mod.Options = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUpdateHelp(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "--check")) {
            opts.check_only = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--release")) {
            if (i + 1 >= args.len) return flagNeedsValue(io, arg);
            i += 1;
            opts.release = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            reportErr(io, "error: unknown option '{s}'\n", .{arg});
            return 2;
        } else {
            reportErr(io, "error: unexpected argument '{s}'\n", .{arg});
            return 2;
        }
    }

    const report = update_mod.run(gpa, io, opts) catch |err| switch (err) {
        error.UnsupportedPlatform => {
            reportErr(io, "error: no published ore binary for this platform yet\n", .{});
            return 1;
        },
        error.ReleaseNotFound => {
            reportErr(io, "error: release '{s}' does not exist or has no ore binary\n", .{opts.release});
            return 1;
        },
        error.ReplaceFailed => {
            reportErr(io, "error: downloaded the update but could not replace '{s}'\n", .{"ore"});
            return 1;
        },
        error.OutOfMemory => {
            reportErr(io, "error: out of memory during update\n", .{});
            return 1;
        },
        else => {
            reportErr(io, "error: update failed: {s}\n", .{@errorName(err)});
            return 1;
        },
    };

    if (opts.check_only) {
        printUpdateStatus(io, report.latest_sha);
        return 0;
    }

    printOut(io, "installed {s} ({d} bytes)\n", .{ report.url, report.size });
    if (report.latest_sha.len > 0) {
        printOut(io, "commit {s}\n", .{report.latest_sha});
    }
    printOut(io, "ore now bundles the Wolframite compiler from that commit.\n", .{});
    if (report.staged) {
        printOut(io, "ore will swap itself into place and exit; run `ore` again to use the new version\n", .{});
    } else {
        printOut(io, "the next time you run ore, it will be the new version\n", .{});
    }
    return 0;
}

/// Print whether the running ore is behind the `release` tag's commit.
fn printUpdateStatus(io: Io, latest_sha: []const u8) void {
    const build_options = @import("build_options");
    if (build_options.git_sha.len == 0) {
        if (latest_sha.len == 0) {
            printOut(io, "could not determine the latest build (offline or release missing)\n", .{});
        } else {
            printOut(io, "this ore was built outside CI (commit unknown); latest dev build is {s}\n", .{latest_sha});
        }
        return;
    }
    if (latest_sha.len == 0) {
        printOut(io, "could not determine the latest build (offline or release missing)\n", .{});
        return;
    }
    if (std.mem.eql(u8, build_options.git_sha, latest_sha)) {
        printOut(io, "up to date (commit {s})\n", .{latest_sha});
    } else {
        printOut(io, "update available: {s} -> {s}\n", .{ build_options.git_sha, latest_sha });
        printOut(io, "run `ore update` to install it\n", .{});
    }
}

fn printUpdateHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore update [options]
        \\
        \\Update ore and the Wolframite compiler bundled inside it. Downloads the
        \\rolling "dev" release (republished by CI on every commit) and swaps
        \\the current executable for the new one.
        \\
        \\Options:
        \\      --check           Only report whether an update is available
        \\  -r, --release <tag>   Install from a different release tag (default: dev)
        \\  -h, --help            Show this help
        \\
    , .{});
}

// ============================================================================
// Shared helpers
// ============================================================================

/// Resolve the source file to compile: an explicit path, else the `entry`
/// from `ore.toml`. Returns `null` (after reporting) when neither exists.
fn resolveSource(gpa: Allocator, io: Io, file: ?[]const u8) !?[]const u8 {
    if (file) |f| return f;

    const manifest_text = std.Io.Dir.cwd().readFileAlloc(io, "ore.toml", gpa, .unlimited) catch {
        reportErr(io, "error: no input file given and no ore.toml found\n", .{});
        reportErr(io, "hint: run `ore init`, or pass a file: `ore build <file.wfr>`\n", .{});
        return null;
    };
    const manifest = try manifest_mod.Manifest.parse(gpa, manifest_text);
    return manifest.entry;
}

fn readSource(gpa: Allocator, io: Io, path: []const u8) ?[]const u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        reportErr(io, "error: could not read '{s}': {s}\n", .{ path, @errorName(err) });
        return null;
    };
    return source;
}

/// Write `text` through a buffered writer into `file` (and flush).
fn writeFile(io: Io, file: std.Io.File, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(file, io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn writeTextFile(io: Io, path: []const u8, text: []const u8) !u8 {
    const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer f.close(io);
    writeFile(io, f, text) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    return 0;
}

/// Write raw bytes (`data`) to `path` — used for binary output such as
/// object files (`.o` / `.obj`).
fn writeBinaryFile(io: Io, path: []const u8, data: []const u8) !u8 {
    const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer f.close(io);
    writeFile(io, f, data) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    return 0;
}

fn reportDiagnostics(io: Io, path: []const u8, diagnostics: *const diag_mod.Diagnostics) void {
    for (diagnostics.items.items) |item| {
        var buf: [4096]u8 = undefined;
        var w: Io.File.Writer = .init(.stderr(), io, &buf);
        if (item.location) |loc| {
            w.interface.print("{s}:{d}:{d}: {s} [{s}]: {s}\n", .{
                path,                 loc.line,
                loc.column,           @tagName(item.severity),
                @tagName(item.phase), item.message,
            }) catch {};
        } else {
            w.interface.print("{s}: {s} [{s}]: {s}\n", .{
                path,
                @tagName(item.severity),
                @tagName(item.phase),
                item.message,
            }) catch {};
        }
        w.interface.flush() catch {};
    }
}

fn flagNeedsValue(io: Io, flag: []const u8) u8 {
    reportErr(io, "error: option '{s}' requires a value\n", .{flag});
    return 2;
}

fn printOut(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn reportErr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn printHelp(io: Io) void {
    printOut(io,
        \\ore {s} — the Wolframite package manager
        \\
        \\Compiles and runs single Wolframite source files today; dependency
        \\management is on the roadmap.
        \\
        \\Usage:
        \\  ore <command> [options]
        \\
        \\Commands:
        \\  init [name]      Scaffold a new package (ore.toml + src/main.wfr)
        \\  build [file]     Compile a .wfr file and link it into an executable via Ferro
        \\  run [file]       Run a previously built executable (does not compile or link)
        \\  update           Update ore (and its bundled compiler) from GitHub releases
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -V, --version    Show version information
        \\
        \\Run `ore <command> --help` for command-specific options.
        \\
    , .{version_string});
}

fn printBuildHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore build [options] [file]
        \\
        \\Compile a single Wolframite source file and link it into an
        \\executable via Ferro. Default output is <input>.exe.
        \\
        \\When no file is given, the entry from ore.toml is used.
        \\
        \\Options:
        \\  -o, --output <path>  Write the executable to <path>
        \\                       (default: <input>.exe)
        \\      --ir             Emit textual Tungsten IR only (no link)
        \\      --obj            Emit a relocatable object file only (no link)
        \\                       (.o on Linux, .obj on Windows)
        \\      --emit-bin       Link into an executable via Ferro (default)
        \\                       (incompatible with --ir)
        \\  -h, --help           Show this help
        \\
        \\Exit codes:
        \\  0  success
        \\  1  compilation, link, or I/O failure
        \\  2  usage error
    , .{});
}

fn printRunHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore run [options] [file] [args...]
        \\
        \\Execute a program previously built with `ore build`. `ore run` does
        \\not compile or link; the executable must already exist. When no file
        \\is given, the entry from ore.toml is used to locate the executable
        \\ (<input>.exe). Arguments after the file are passed to the program.
        \\
        \\Options:
        \\  -o, --output <path>  Run the executable at <path>
        \\                       (default: <input>.exe)
        \\  -h, --help           Show this help
        \\
    , .{});
}
