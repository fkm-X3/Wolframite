//! ore — the Wolframite package manager.
//!
//! Currently a single-file build tool wrapping the full compiler pipeline
//! (see `compile.zig`), with package scaffolding (`init`), a run mode that
//! compiles to an object + links via Ferro (`run`, `build --emit-bin`),
//! zero-config cross-compilation to a target triple
//! (`build --target <triple>`, see `docs/cross-compilation.md`), and a
//! self-update command that installs new ore releases (which bundle the
//! compiler) from GitHub (`update`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const ferro = @import("Tungsten").ferro;
const ferro_reader = @import("Tungsten").ferro_reader;
const check_codegen = @import("Tungsten").check_codegen;
const manifest_mod = @import("manifest.zig");
const compile_mod = @import("compile.zig");
const link_mod = @import("link.zig");
const update_mod = @import("update.zig");
const disasm_mod = @import("disasm.zig");

const replaceExt = link_mod.replaceExt;
const targetObjectExt = link_mod.targetObjectExt;
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
    if (std.mem.eql(u8, command, "check-codegen")) return cmdCheckCodegen(gpa, io, rest);
    if (std.mem.eql(u8, command, "disasm")) return disasm_mod.cmdDisasm(gpa, io, rest);
    if (std.mem.eql(u8, command, "trace")) return cmdTrace(gpa, io, rest);
    if (std.mem.eql(u8, command, "test")) return cmdTest(gpa, io, rest);
    if (std.mem.eql(u8, command, "fmt") or std.mem.eql(u8, command, "format")) return cmdFmt(gpa, io, rest);
    if (std.mem.eql(u8, command, "smelt")) return cmdSmelt(gpa, io, rest);    reportErr(io, "error: unknown command '{s}'\n", .{command});
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

/// Default location for a built executable: `wfr-bin/<stem>.exe`, keeping
/// built binaries out of the source tree. Only used when the caller does not
/// pass `-o`/`--output`.
fn defaultBinPath(gpa: Allocator, source_path: []const u8) ![]u8 {
    const stem = std.fs.path.stem(source_path);
    return std.fmt.allocPrint(gpa, "wfr-bin{c}{s}.exe", .{ std.fs.path.sep, stem });
}

fn cmdBuild(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var mode: compile_mod.EmitMode = .obj;
    var emit_bin = true;
    var emit_bin_explicit = false;
    var dump_image = false;
    var emit_annotated = false;
    var target = hostTarget();
    var target_given = false;
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
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (i + 1 >= args.len) return flagNeedsValue(io, arg);
            i += 1;
            target = ferro.parseTarget(args[i]) catch {
                reportErr(io, "error: unknown target '{s}'\n", .{args[i]});
                reportErr(io, "       expected 'linux', 'windows', or an x86_64 target triple\n", .{});
                reportErr(io, "       such as 'x86_64-microsoft-windows' or\n", .{});
                reportErr(io, "       'x86_64-unknown-linux'\n", .{});
                return 2;
            };
            target_given = true;
        } else if (std.mem.eql(u8, arg, "--ir")) {
            mode = .ir;
            emit_bin = false;
        } else if (std.mem.eql(u8, arg, "--obj")) {
            mode = .obj;
            emit_bin = false;
        } else if (std.mem.eql(u8, arg, "--emit-bin")) {
            emit_bin = true;
            emit_bin_explicit = true;
        } else if (std.mem.eql(u8, arg, "--dump-image")) {
            dump_image = true;
        } else if (std.mem.eql(u8, arg, "--emit-annotated")) {
            emit_annotated = true;
            emit_bin = false;
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

    // Cross-compiling with --target defaults to emitting a relocatable object
    // for the target: that needs nothing but the compiler, while the Ferro
    // link step also needs the target's runtime archive. --emit-bin opts into
    // linking an executable (see docs/cross-compilation.md).
    if (target_given and !emit_bin_explicit and !emit_annotated and mode == .obj) {
        emit_bin = false;
    }

    const source_path = (try resolveSource(gpa, io, file)) orelse return 2;

    if (emit_annotated) {
        const source = readSource(gpa, io, source_path) orelse return 1;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const result = try compile_mod.compileAnnotated(arena.allocator(), source, target, false);
        if (!result.ok) {
            reportDiagnostics(io, source_path, &result.diagnostics);
            reportErr(io, "error: compilation failed\n", .{});
            return 1;
        }
        const obj_path = out_path orelse try replaceExt(gpa, source_path, targetObjectExt(target));
        if ((try writeBinaryFile(io, obj_path, result.obj_bytes)) != 0) return 1;
        printOut(io, "wrote {s}\n", .{obj_path});
        return 0;
    }

    if (emit_bin) {
        const exe_path = out_path orelse try defaultBinPath(gpa, source_path);
        if (out_path == null) {
            // Keep built binaries out of the source tree.
            std.Io.Dir.cwd().createDirPath(io, "wfr-bin") catch {};
        }
        link_mod.linkBinary(io, gpa, source_path, exe_path, dump_image, false, target) catch |err| switch (err) {
            link_mod.LinkError.CompileFailed => {
                reportErr(io, "error: compilation failed\n", .{});
                return 1;
            },
            link_mod.LinkError.LinkFailed => {
                reportErr(io, "error: link failed (ferro link error)\n", .{});
                return 1;
            },
            link_mod.LinkError.StdLibMissing => {
                reportErr(io, "error: could not find the Wolframite runtime archive 'wfr_std'\n", .{});
                if (target != hostTarget()) {
                    reportErr(io, "       the runtime for the {s} target is not installed\n", .{@tagName(target)});
                    reportErr(io, "       run 'zig build -Dtarget={s}' from the repository root first\n", .{link_mod.zigTargetName(target)});
                } else {
                    reportErr(io, "       run 'zig build' from the repository root first\n", .{});
                }
                return 1;
            },
        };
        printOut(io, "wrote {s}\n", .{exe_path});
        return 0;
    }

    const source = readSource(gpa, io, source_path) orelse return 1;

    const result = compile_mod.compile(gpa, source, mode, target, false) catch |err| {
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
        .obj => {
            const obj_path = out_path orelse try replaceExt(gpa, source_path, targetObjectExt(target));
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

    const exe_path = out_path orelse try defaultBinPath(gpa, source_path);

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
// check-codegen
// ============================================================================

/// `ore check-codegen <file>` — statically verify a Tungsten-emitted object file
/// for byte-level codegen encoding bugs before linking.
fn cmdCheckCodegen(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    if (args.len == 0) {
        reportErr(io, "error: check-codegen requires an object file\n", .{});
        reportErr(io, "usage: ore check-codegen <file.o>\n", .{});
        return 2;
    }
    if (args.len > 1) {
        reportErr(io, "error: unexpected argument '{s}'\n", .{args[1]});
        return 2;
    }
    const path = args[0];
    var obj = try ferro_reader.readObject(io, gpa, path);
    defer obj.deinit(gpa);
    var report = try check_codegen.checkObject(gpa, &obj);
    defer report.deinit(gpa);

    if (report.violations.items.len == 0) {
        printOut(io, "check-codegen: {s}: no violations\n", .{path});
        return 0;
    }

    reportErr(io, "check-codegen: {s}: {d} violation(s)\n", .{ path, report.violations.items.len });
    for (report.violations.items) |v| {
        var bytes: [16]u8 = undefined;
        var i: usize = 0;
        while (i < v.byte_len) : (i += 1) {
            bytes[i] = v.bytes[i];
        }
        reportErr(io, "  {s}:{d}: {s} (bytes: {x})\n", .{
            path, v.offset, v.message, bytes[0..@as(usize, v.byte_len)],
        });
    }
    return 1;
}

fn printCheckCodegenHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore check-codegen <file.o>
        \\
        \\Statically verify a Tungsten-emitted relocatable object file for
        \\byte-level codegen encoding bugs (truncated immediates, missing
        \\ModR/M bytes, bad SIB index, inconsistent REX prefixes, unresolved
        \\branch targets) before linking.
        \\
        \\Exit codes:
        \\  0  no violations
        \\  1  one or more violations found
        \\  2  usage error
    , .{});
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

// ============================================================================
// smelt
// ============================================================================

fn cmdSmelt(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var file_override: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var direct_file = false;
    var prog_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printSmeltHelp(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            if (i + 1 >= args.len) return flagNeedsValue(io, arg);
            i += 1;
            file_override = args[i];
        } else if (arg.len > 0 and arg[0] == '-' and command == null and file_override == null) {
            reportErr(io, "error: unknown option '{s}'\n", .{arg});
            return 2;
        } else if (command == null) {
            // An existing file path (when no explicit smeltfile) is treated as
            // a file to compile & run directly.
            if (file_override == null) {
                if (std.Io.Dir.cwd().access(io, arg, .{})) |_| {
                        direct_file = true;
                    file_override = arg;
                } else |_| {
                    command = arg;
                }
            } else {
                command = arg;
            }
        } else {
            try prog_args.append(gpa, arg);
        }
    }

    const smelt_path = blk: {
        if (file_override) |f| break :blk f;
        // search default smeltfile names
        const names = [_][]const u8{ "smeltfile", "smeltfile.wfr", "smelt", "smelt.wfr", "build", "build.wfr", "Smeltfile", "Smeltfile.wfr" };
        for (names) |name| {
            if (std.Io.Dir.cwd().access(io, name, .{})) |_| {
                break :blk name;
            } else |_| {}
        }
        break :blk null;
    };

    if (smelt_path == null) {
        if (command) |c| {
            reportErr(io, "error: no smeltfile found (looked for smeltfile.wfr, smelt.wfr, build.wfr)\n", .{});
            reportErr(io, "       unknown command '{s}'\n", .{c});
        } else {
            reportErr(io, "error: no smeltfile found (looked for smeltfile.wfr, smelt.wfr, build.wfr)\n", .{});
            reportErr(io, "hint: create a smeltfile.wfr, or pass a file: `ore smelt <file.wfr>`\n", .{});
        }
        return 2;
    }

    const source_path = smelt_path.?;

    // Direct file mode: just compile & run it.
    if (direct_file) {
        return runWfrFile(gpa, io, source_path, prog_args.items);
    }

    const source = readSource(gpa, io, source_path) orelse return 1;

    // No command: run the smeltfile's main (if any) or list commands.
    if (command == null) {
        if (containsFn(source, "main")) {
            return runWfrFile(gpa, io, source_path, prog_args.items);
        }
        // list available commands
        const cmds = @import("compiler").smeltfile.compileSmeltfile(gpa, source) catch {
            reportErr(io, "error: could not parse smeltfile '{s}'\n", .{source_path});
            return 1;
        };
        printOut(io, "smeltfile: {s}\n", .{source_path});
        printOut(io, "available commands:\n", .{});
        for (cmds) |cmd| {
            printOut(io, "  {s}\n", .{cmd.name});
        }
        if (cmds.len == 0) {
            printOut(io, "  (none)\n", .{});
        }
        printOut(io, "usage: ore smelt <command>\n", .{});
        return 0;
    }

    const cmd_name = command.?;

    // Function dispatch: if the smeltfile defines a function with that name,
    // compile a wrapper that calls it as the entry point.
    if (containsFn(source, cmd_name)) {
        // Write a wrapper source combining the original + a main shim.
        // If the original already defines `fn main`, rename it to avoid a
        // duplicate declaration in the wrapper.
        const renamed = if (containsFn(source, "main"))
            std.mem.replaceOwned(u8, gpa, source, "fn main", "fn __smelt_main") catch source
        else
            source;
        const wrapper_path = "smelt_wrapper.wfr";
        const wf = std.Io.Dir.cwd().createFile(io, wrapper_path, .{}) catch |err| {
            reportErr(io, "error: could not write wrapper: {s}\n", .{@errorName(err)});
            return 1;
        };
        const shim = std.fmt.allocPrint(gpa, "\n\nfn main() -> i32 {{\n    return {s}()\n}}\n", .{cmd_name}) catch {
            wf.close(io);
            reportErr(io, "error: out of memory\n", .{});
            return 1;
        };
        const wrapper_source = std.mem.concat(gpa, u8, &.{ renamed, shim }) catch {
            wf.close(io);
            reportErr(io, "error: out of memory\n", .{});
            return 1;
        };
        writeFile(io, wf, wrapper_source) catch {
            wf.close(io);
            return 1;
        };
        wf.close(io);
        const rc = runWfrFile(gpa, io, wrapper_path, prog_args.items);
        std.Io.Dir.cwd().deleteFile(io, wrapper_path) catch {};
        return rc;
    }

    // Declarative command: extract from smeltfile.
    const smelt_mod = @import("compiler").smeltfile;
    const smelt_cmd = smelt_mod.compileSmeltCommand(gpa, source, cmd_name) catch |err| {
        reportErr(io, "error: no command '{s}' in smeltfile '{s}' ({s})\n", .{ cmd_name, source_path, @errorName(err) });
        return 2;
    };

    // Shell command task.
    if (smelt_cmd.command.len > 0) {
        return runShellCommand(io, gpa, smelt_cmd.command);
    }

    if (smelt_cmd.entry.len == 0) {
        reportErr(io, "error: command '{s}' has no 'entry' or 'command' field\n", .{cmd_name});
        return 2;
    }

    const target = if (smelt_cmd.target.len > 0)
        (ferro.parseTarget(smelt_cmd.target) catch {
            reportErr(io, "error: unknown target '{s}'\n", .{smelt_cmd.target});
            return 2;
        })
    else
        hostTarget();

    const output = if (smelt_cmd.output.len > 0)
        try gpa.dupe(u8, smelt_cmd.output)
    else
        try defaultBinPath(gpa, smelt_cmd.entry);

    if (smelt_cmd.output.len == 0) {
        std.Io.Dir.cwd().createDirPath(io, "wfr-bin") catch {};
    }

    link_mod.linkBinary(io, gpa, smelt_cmd.entry, output, false, smelt_cmd.test_mode, target) catch |err| switch (err) {
        link_mod.LinkError.CompileFailed => {
            reportErr(io, "error: compilation failed\n", .{});
            return 1;
        },
        link_mod.LinkError.LinkFailed => {
            reportErr(io, "error: link failed\n", .{});
            return 1;
        },
        link_mod.LinkError.StdLibMissing => {
            reportErr(io, "error: could not find wfr_std runtime\n", .{});
            return 1;
        },
    };
    printOut(io, "built {s}\n", .{output});

    if (smelt_cmd.run or prog_args.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(gpa, output);
        try argv.appendSlice(gpa, prog_args.items);
        const argv_slice = try argv.toOwnedSlice(gpa);
        var child = spawnOrShell(io, gpa, output, argv_slice) catch |err| {
            reportErr(io, "error: could not start '{s}': {s}\n", .{ output, @errorName(err) });
            return 1;
        };
        const term = child.wait(io) catch |err| {
            reportErr(io, "error: could not wait for '{s}': {s}\n", .{ output, @errorName(err) });
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
    return 0;
}

fn runWfrFile(gpa: Allocator, io: Io, source_path: []const u8, prog_args: []const []const u8) !u8 {
    const exe_path = try defaultBinPath(gpa, source_path);
    std.Io.Dir.cwd().createDirPath(io, "wfr-bin") catch {};
    link_mod.linkBinary(io, gpa, source_path, exe_path, false, false, hostTarget()) catch |err| switch (err) {
        link_mod.LinkError.CompileFailed => {
            reportErr(io, "error: compilation failed\n", .{});
            return 1;
        },
        link_mod.LinkError.LinkFailed => {
            reportErr(io, "error: link failed\n", .{});
            return 1;
        },
        link_mod.LinkError.StdLibMissing => {
            reportErr(io, "error: could not find wfr_std runtime\\n", .{});
            return 1;
        },
    };
    printOut(io, "wrote {s}\\n", .{exe_path});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, exe_path);
    try argv.appendSlice(gpa, prog_args);
    const argv_slice = try argv.toOwnedSlice(gpa);

    var child = spawnOrShell(io, gpa, exe_path, argv_slice) catch |err| {
        reportErr(io, "error: could not start '{s}': {s}\\n", .{ exe_path, @errorName(err) });
        return 1;
    };
    const term = child.wait(io) catch |err| {
        reportErr(io, "error: could not wait for '{s}': {s}\\n", .{ exe_path, @errorName(err) });
        return 1;
    };
    switch (term) {
        .exited => |code| return code,
        else => {
            reportErr(io, "error: program terminated abnormally\\n", .{});
            return 1;
        },
    }
}

fn containsFn(source: []const u8, name: []const u8) bool {
    // crude: look for "fn <name>" 
    var buf: [256]u8 = undefined;
    if (name.len + 4 > buf.len) return false;
    var i: usize = 0;
    buf[i] = 'f'; i += 1;
    buf[i] = 'n'; i += 1;
    buf[i] = ' '; i += 1;
    for (name) |c| { buf[i] = c; i += 1; }
    const needle = buf[0..i];
    return std.mem.indexOf(u8, source, needle) != null;
}

fn runShellCommand(io: Io, gpa: Allocator, cmd: []const u8) !u8 {
    _ = gpa;
    const shell_cmd = switch (builtin.os.tag) {
        .windows => "cmd",
        else => "sh",
    };
    const shell_arg = switch (builtin.os.tag) {
        .windows => "/c",
        else => "-c",
    };
    var child = std.process.spawn(io, .{
        .argv = &.{ shell_cmd, shell_arg, cmd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        reportErr(io, "error: could not start shell command: {s}\\n", .{@errorName(err)});
        return 1;
    };
    const term = child.wait(io) catch |err| {
        reportErr(io, "error: could not wait: {s}\\n", .{@errorName(err)});
        return 1;
    };
    switch (term) {
        .exited => |code| return code,
        else => return 1,
    }
}

fn printSmeltHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore smelt [options] [command] [args...]
        \\
        \\Run a command defined in a smeltfile (smeltfile.wfr by default).
        \\A smeltfile is a normal Wolframite module: commands may be functions
        \\  (invoked by name) or declarative tasks with an 'entry' field.
        \\
        \\Options:
        \\  -f, --file <path>  Use <path> as the smeltfile
        \\  -h, --help         Show this help
        \\
    , .{});
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
        \\  check-codegen <file>
        \\                   Statically verify a Tungsten object file for codegen bugs
        \\  disasm <file>
        \\                   Disassemble a Tungsten object file with relocation annotations
        \\  test [file]      Build and run a program as an integrated test
        \\  fmt [file]       Format a Wolframite source file in place
        \\  smelt [command]  Run a command defined in a smeltfile
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
        \\executable via Ferro. Default output is wfr-bin/<input>.exe.
        \\With --target, the default output is instead a relocatable object
        \\for the target: cross-compiling needs no linker and no runtime.
        \\
        \\When no file is given, the entry from ore.toml is used.
        \\
        \\Options:
        \\  -o, --output <path>    Write the output to <path>
        \\                         (default: wfr-bin/<input>.exe when linking,
        \\                         <input>.o / .obj for objects)
        \\      --target <triple>  Cross-compile for <triple>: 'linux',
        \\                         'windows', or an x86_64 target triple
        \\                         such as x86_64-microsoft-windows or
        \\                         x86_64-unknown-linux. Defaults to
        \\                         object output; add --emit-bin to link.
        \\      --ir               Emit textual Tungsten IR only (no link)
        \\      --obj              Emit a relocatable object file only (no link)
        \\                         (.o on Linux targets, .obj on Windows targets)
        \\      --emit-bin         Link into an executable via Ferro (default
        \\                         without --target; incompatible with --ir)
        \\      --dump-image       Print Ferro's merged image (section sizes,
        \\                         symbol addresses, relocations before/after)
        \\                         to stderr before writing the executable
        \\      --emit-annotated   Emit a relocatable object file (.o / .obj)
        \\                         without asm output
        \\  -h, --help             Show this help
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
        \\ (wfr-bin/<input>.exe). Arguments after the file are passed to the program.
        \\
        \\Options:
        \\  -o, --output <path>  Run the executable at <path>
        \\                       (default: wfr-bin/<input>.exe)
        \\  -h, --help           Show this help
        \\
    , .{});
}

/// `ore test <file> [args...]` — build the program and run it as a test
/// suite. A test run succeeds when the compiled program exits with status 0;
/// any non-zero exit (or abnormal termination) is reported as a failure.
fn cmdTest(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var prog_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printTestHelp(io);
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
    const exe_path = out_path orelse try defaultBinPath(gpa, source_path);

    if (out_path == null) {
        std.Io.Dir.cwd().createDirPath(io, "wfr-bin") catch {};
    }

    link_mod.linkBinary(io, gpa, source_path, exe_path, false, true, hostTarget()) catch |err| switch (err) {
        link_mod.LinkError.CompileFailed => {
            reportErr(io, "error: compilation failed\n", .{});
            reportErr(io, "test result: FAILED (compile/link)\n", .{});
            return 1;
        },
        link_mod.LinkError.LinkFailed => {
            reportErr(io, "error: link failed (ferro link error)\n", .{});
            reportErr(io, "test result: FAILED (link)\n", .{});
            return 1;
        },
        link_mod.LinkError.StdLibMissing => {
            reportErr(io, "error: could not find the Wolframite runtime archive 'wfr_std'\n", .{});
            reportErr(io, "       run 'zig build' from the repository root first\n", .{});
            reportErr(io, "test result: FAILED (runtime missing)\n", .{});
            return 1;
        },
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, exe_path);
    try argv.appendSlice(gpa, prog_args.items);
    const argv_slice = try argv.toOwnedSlice(gpa);

    printOut(io, "test: running '{s}'\n", .{exe_path});

    var child = spawnOrShell(io, gpa, exe_path, argv_slice) catch |err| {
        reportErr(io, "error: could not start '{s}': {s}\n", .{ exe_path, @errorName(err) });
        reportErr(io, "test result: FAILED (could not start)\n", .{});
        return 1;
    };
    const term = child.wait(io) catch |err| {
        reportErr(io, "error: could not wait for '{s}': {s}\n", .{ exe_path, @errorName(err) });
        reportErr(io, "test result: FAILED (wait)\n", .{});
        return 1;
    };

    switch (term) {
        .exited => |code| {
            if (code == 0) {
                printOut(io, "test result: ok\n", .{});
            } else {
                reportErr(io, "test result: FAILED (exit code {d})\n", .{code});
            }
            return code;
        },
        else => {
            reportErr(io, "test result: FAILED (abnormal termination)\n", .{});
            return 1;
        },
    }
}

fn printTestHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore test [options] [file] [args...]
        \\
        \\Build a Wolframite program and run it as an integrated test.
        \\The test passes when the program exits with status 0.
        \\
        \\Options:
        \\  -o, --output <path>  Build/run the executable at <path>
        \\  -h, --help           Show this help
        \\
    , .{});
}

// ============================================================================
// fmt
// ============================================================================

fn cmdFmt(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var check = false;
    var to_stdout = false;
    var file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printFmtHelp(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            to_stdout = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--write")) {
            // default behaviour; accepted for compatibility
        } else if (arg.len > 0 and arg[0] == '-' and file == null) {
            reportErr(io, "error: unknown option '{s}'\n", .{arg});
            return 2;
        } else if (file == null) {
            file = arg;
        } else {
            reportErr(io, "error: unexpected argument '{s}'\n", .{arg});
            return 2;
        }
    }

    const source_path = (try resolveSource(gpa, io, file)) orelse return 2;
    const source = readSource(gpa, io, source_path) orelse return 1;

    const formatted = @import("compiler").formatter.format(gpa, source) catch |err| {
        reportErr(io, "error: could not format '{s}': {s}\n", .{ source_path, @errorName(err) });
        return 1;
    };

    if (check) {
        if (std.mem.eql(u8, source, formatted)) return 0;
        reportErr(io, "error: '{s}' is not formatted\n", .{source_path});
        return 1;
    }

    if (to_stdout) {
        printOut(io, "{s}", .{formatted});
        return 0;
    }

    // In-place write.
    const f = std.Io.Dir.cwd().createFile(io, source_path, .{}) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ source_path, @errorName(err) });
        return 1;
    };
    defer f.close(io);
    writeFile(io, f, formatted) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ source_path, @errorName(err) });
        return 1;
    };
    return 0;
}

fn printFmtHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore fmt [options] [file]
        \\  ore format [options] [file]
        \\
        \\Format a Wolframite source file in place using the built-in formatter.
        \\
        \\Options:
        \\      --check     Check if the file is formatted; do not write
        \\      --stdout    Print the formatted source to stdout
        \\  -h, --help      Show this help
        \\
    , .{});
}

fn printTraceHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore trace [options] [file] [args...]
        \\
        \\Execute a program previously built with `ore build` and report how
        \\the run ended (exit code or crash). The executable must already
        \\exist; `ore trace` does not compile or link.
        \\
        \\Options:
        \\  -o, --output <path>  Trace the executable at <path>
        \\                       (default: wfr-bin/<input>.exe)
        \\  -h, --help           Show this help
        \\
    , .{});
}

/// `ore trace <file> [args...]` — execute a program and report how the run
/// ended (exit code or crash). Wraps execution and captures the termination
/// report.
fn cmdTrace(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var prog_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printTraceHelp(io);
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

    const exe_path = out_path orelse try defaultBinPath(gpa, source_path);

    // `ore trace` only executes a binary already produced by `ore build`.
    if (!link_mod.fileExists(io, exe_path)) {
        reportErr(io, "error: executable '{s}' not found\n", .{exe_path});
        reportErr(io, "       run `ore build` first\n", .{});
        return 1;
    }

    printOut(io, "trace: executing '{s}'\n", .{exe_path});

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
        .exited => |code| {
            printOut(io, "trace: '{s}' exited with code {d}\n", .{ exe_path, code });
            return code;
        },
        else => {
            reportErr(io, "trace: '{s}' terminated abnormally\n", .{exe_path});
            return 1;
        },
    }
}
