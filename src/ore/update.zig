//! ore update — self-update from GitHub releases.
//!
//! ore bundles the Wolframite compiler pipeline, so installing a newer ore
//! binary also updates the compiler. ore fetches the rolling "dev" release
//! (republished by CI on every commit) and swaps the current executable for
//! the downloaded one.
//!
//! A running executable cannot be renamed on Windows, so the swap happens in
//! a helper process: `ore update` stages the new binary as `<exe>.staged`,
//! spawns a copy of itself (`<exe>.updater`) with `--apply-update`, and the
//! helper retries the rename until the original ore process exits. On POSIX
//! the swap is done in-process, since renaming a running executable there is
//! allowed.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;

const Owner = "fkm-X3";
const Repo = "Wolframite";

/// The rolling release name published by `.github/workflows/dev-release.yml`.
pub const default_release = "dev";

/// Marker subcommand used by the self-update helper process (internal).
pub const apply_update_marker = "--apply-update";

pub const Options = struct {
    /// GitHub release tag to install from.
    release: []const u8 = default_release,
    /// Only report whether an update is available; do not download.
    check_only: bool = false,
};

pub const Report = struct {
    /// Download URL of the matching ore asset for this platform.
    url: []const u8,
    /// Size in bytes of the binary that was downloaded (0 in check mode).
    size: u64,
    /// Whether the swap already happened in this process (POSIX).
    installed: bool,
    /// Whether the swap was deferred to the updater helper (Windows).
    staged: bool,
    /// Commit SHA the `release` tag points at ("" when it could not be read).
    latest_sha: []const u8,
};

pub const UpdateError = error{
    UnsupportedPlatform,
    ReleaseNotFound,
    ReplaceFailed,
    IOException,
} || std.process.ExecutablePathAllocError || Allocator.Error;

/// Asset file name for the current build target, or `null` when ore does
/// not publish a binary for this platform.
///
/// The dev release publishes archives (zip on Windows, tar.gz on Linux)
/// containing the same `bin/` + `lib/` layout as `zig-out/`.
pub fn assetName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "ore-windows-x86_64.zip",
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "ore-linux-x86_64.tar.gz",
            else => null,
        },
        else => null,
    };
}

/// Archive file extension for the current platform.
pub fn archiveSuffix() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".zip",
        .linux => ".tar.gz",
        else => "",
    };
}

/// Executable extension for the current platform.
pub fn exeExt() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".exe",
        else => "",
    };
}

/// Runtime library file name for the current platform.
pub fn wfrStdName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "wfr_std.lib",
        .linux => "libwfr_std.a",
        else => "",
    };
}

fn downloadUrl(gpa: Allocator, release: []const u8, asset: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ Owner, Repo, release, asset },
    );
}

fn refUrl(gpa: Allocator, release: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        "https://api.github.com/repos/{s}/{s}/git/refs/tags/{s}",
        .{ Owner, Repo, release },
    );
}

pub fn run(gpa: Allocator, io: Io, opts: Options) UpdateError!Report {
    const asset = assetName() orelse return error.UnsupportedPlatform;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const latest_sha = fetchRefSha(gpa, &client, opts.release) catch "";
    const url = try downloadUrl(gpa, opts.release, asset);

    if (opts.check_only) {
        return .{
            .url = url,
            .size = 0,
            .installed = false,
            .staged = false,
            .latest_sha = latest_sha,
        };
    }

    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);
    const paths = try siblingPaths(gpa, exe_path);
    defer {
        // paths.dir is a sub-slice of exe_path (freed above); only the
        // allocPrint-allocated strings need individual freeing.
        gpa.free(paths.staged);
        gpa.free(paths.updater);
        gpa.free(paths.old);
    }

    // Download the archive (zip on Windows, tar.gz on Linux) next to the exe.
    const archive_path = try std.fmt.allocPrint(
        gpa,
        "{s}{c}ore-update{s}",
        .{ paths.dir, std.fs.path.sep, archiveSuffix() },
    );
    defer std.Io.Dir.deleteFileAbsolute(io, archive_path) catch {};
    const download_size = try downloadTo(io, &client, url, archive_path);

    // Extract the archive into a staging directory next to the exe.
    const staging_dir = try std.fmt.allocPrint(
        gpa,
        "{s}{c}ore-update-staging",
        .{ paths.dir, std.fs.path.sep },
    );
    std.Io.Dir.deleteFileAbsolute(io, staging_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, staging_dir) catch {};
    try extractArchive(io, archive_path, staging_dir);

    // Copy the ore binary from the archive to paths.staged for the swap.
    const ore_in_archive = try std.fmt.allocPrint(
        gpa,
        "{s}{c}bin{c}ore{s}",
        .{ staging_dir, std.fs.path.sep, std.fs.path.sep, exeExt() },
    );
    defer gpa.free(ore_in_archive);
    std.Io.Dir.copyFileAbsolute(ore_in_archive, paths.staged, io, .{ .replace = true }) catch {
        std.Io.Dir.deleteFileAbsolute(io, paths.staged) catch {};
        return error.IOException;
    };

    // Copy the runtime library from the archive to the install lib dir.
    // The install layout mirrors zig-out/: <exedir>/../lib/wfr_std(.lib|.a)
    const exe_dir = std.fs.path.dirname(paths.dir) orelse return error.UnsupportedPlatform;
    defer gpa.free(exe_dir);
    const lib_dir = try std.fmt.allocPrint(gpa, "{s}{c}lib", .{ exe_dir, std.fs.path.sep });
    defer gpa.free(lib_dir);
    const wfr_in_archive = try std.fmt.allocPrint(
        gpa,
        "{s}{c}lib{c}{s}",
        .{ staging_dir, std.fs.path.sep, std.fs.path.sep, wfrStdName() },
    );
    defer gpa.free(wfr_in_archive);
    const wfr_dest = try std.fmt.allocPrint(
        gpa,
        "{s}{c}{s}",
        .{ lib_dir, std.fs.path.sep, wfrStdName() },
    );
    defer gpa.free(wfr_dest);
    std.Io.Dir.copyFileAbsolute(wfr_in_archive, wfr_dest, io, .{ .replace = true }) catch {
        // Non-fatal: the ore binary itself was still updated.
        std.debug.print("[wolframite] warning: could not install runtime to {s}\n", .{ wfr_dest });
    };

    if (builtin.os.tag == .windows) {
        try stageForSwap(gpa, io, exe_path, paths);
    } else {
        try swapInPlace(io, exe_path, paths);
    }

    return .{
        .url = url,
        .size = download_size,
        .installed = builtin.os.tag != .windows,
        .staged = builtin.os.tag == .windows,
        .latest_sha = latest_sha,
    };
}

/// Read the commit SHA the release tag points at ("" when it is missing).
fn fetchRefSha(gpa: Allocator, client: *http.Client, release: []const u8) ![]const u8 {
    const url = try refUrl(gpa, release);
    var aw: Io.Writer.Allocating = .init(gpa);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch return error.ReleaseNotFound;

    if (result.status != .ok) return error.ReleaseNotFound;
    const body = try aw.toOwnedSlice();

    const parsed = std.json.parseFromSliceLeaky(
        struct { object: struct { sha: []const u8 } },
        gpa,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.ReleaseNotFound;

    if (parsed.object.sha.len == 0) return error.ReleaseNotFound;
    return parsed.object.sha;
}

/// Sibling file names next to the running executable.
pub const SiblingPaths = struct {
    dir: []const u8,
    staged: []u8,
    updater: []u8,
    old: []u8,
};

fn siblingPaths(gpa: Allocator, exe_path: []const u8) !SiblingPaths {
    const dir = std.fs.path.dirname(exe_path).?;
    return .{
        .dir = dir,
        .staged = try std.fmt.allocPrint(gpa, "{s}{c}ore.staged", .{ dir, std.fs.path.sep }),
        .updater = try std.fmt.allocPrint(gpa, "{s}{c}ore.updater", .{ dir, std.fs.path.sep }),
        .old = try std.fmt.allocPrint(gpa, "{s}{c}ore.old", .{ dir, std.fs.path.sep }),
    };
}

/// Stream `url` into `path`; returns the number of bytes written.
fn downloadTo(io: Io, client: *http.Client, url: []const u8, path: []const u8) UpdateError!u64 {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var file: std.Io.File = undefined;
    var buf: [8192]u8 = undefined;
    var fw: Io.File.Writer = undefined;

    file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return error.IOException;
    fw = Io.File.Writer.init(file, io, &buf);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &fw.interface,
    }) catch {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        return error.IOException;
    };
    fw.interface.flush() catch {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        return error.IOException;
    };
    file.close(io);

    if (result.status != .ok) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        return error.ReleaseNotFound;
    }

    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.IOException;
    return stat.size;
}

/// Extract a downloaded archive (zip on Windows, tar.gz on Linux) into
/// `dest_dir`. The archive contains the same `bin/` + `lib/` layout as
/// `zig-out/`. `dest_dir` must already exist.
fn extractArchive(io: Io, archive_path: []const u8, dest_dir: []const u8) UpdateError!void {
    const dest = std.Io.Dir.openDirAbsolute(io, dest_dir, .{}) catch return error.IOException;
    defer std.Io.Dir.close(dest, io);

    const file = std.Io.Dir.cwd().openFile(io, archive_path, .{}) catch return error.IOException;
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);

    if (std.mem.endsWith(u8, archive_path, ".zip")) {
        std.zip.extract(dest, &reader, .{}) catch return error.IOException;
        return;
    }

    // .tar.gz: decompress gzip then extract tar
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&reader.interface, .gzip, &flate_buffer);
    std.tar.extract(io, dest, &decompress.reader, .{}) catch return error.IOException;
}

/// Swap in-place: allowed on POSIX, where a running executable may be
/// renamed. The running image keeps executing; the next launch is the new one.
/// Assumes `paths.staged` already contains the new binary.
fn swapInPlace(io: Io, exe_path: []const u8, paths: SiblingPaths) UpdateError!void {
    std.Io.Dir.deleteFileAbsolute(io, paths.old) catch {};
    std.Io.Dir.renameAbsolute(exe_path, paths.old, io) catch {
        std.Io.Dir.deleteFileAbsolute(io, paths.staged) catch {};
        return error.ReplaceFailed;
    };
    std.Io.Dir.renameAbsolute(paths.staged, exe_path, io) catch {
        std.Io.Dir.renameAbsolute(paths.old, exe_path, io) catch {};
        std.Io.Dir.deleteFileAbsolute(io, paths.staged) catch {};
        return error.ReplaceFailed;
    };
    std.Io.Dir.deleteFileAbsolute(io, paths.old) catch {};
}

/// Stage the update for a helper process: copy the current binary to
/// `<exe>.updater`, and spawn it with `--apply-update`. Assumes `paths.staged`
/// already contains the new binary.
fn stageForSwap(gpa: Allocator, io: Io, exe_path: []const u8, paths: SiblingPaths) UpdateError!void {
    // The updater from a previous update may still be lying around.
    std.Io.Dir.deleteFileAbsolute(io, paths.updater) catch {};
    std.Io.Dir.copyFileAbsolute(exe_path, paths.updater, io, .{ .replace = true }) catch {
        std.Io.Dir.deleteFileAbsolute(io, paths.staged) catch {};
        return error.IOException;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, paths.updater);
    try argv.append(gpa, apply_update_marker);
    try argv.append(gpa, exe_path);
    try argv.append(gpa, paths.staged);
    const argv_slice = try argv.toOwnedSlice(gpa);

    _ = std.process.spawn(io, .{
        .argv = argv_slice,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        std.Io.Dir.deleteFileAbsolute(io, paths.staged) catch {};
        return error.IOException;
    };
}

/// Helper entrypoint: retries renaming the (no longer running) ore executable
/// aside, moves the staged binary into place, and cleans up. `args` is
/// `[exe_path, staged_path]`. Runs from the `ore.updater` copy so it is not
/// itself locked. Returns a process exit code.
pub fn applyUpdate(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    if (args.len < 2) return 1;
    const exe_path = args[0];
    const staged_path = args[1];
    const paths = try siblingPaths(gpa, exe_path);

    // The ore process that staged the update exits right after spawning us;
    // give it a moment and then keep retrying until the file is free.
    var attempts: usize = 0;
    while (attempts < 150) : (attempts += 1) {
        std.Io.Dir.deleteFileAbsolute(io, paths.old) catch {};
        std.Io.Dir.renameAbsolute(exe_path, paths.old, io) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .boot) catch {};
            continue;
        };
        break;
    }
    if (attempts >= 150) {
        return error.ReplaceFailed;
    }

    std.Io.Dir.renameAbsolute(staged_path, exe_path, io) catch {
        std.Io.Dir.renameAbsolute(paths.old, exe_path, io) catch {};
        return error.ReplaceFailed;
    };
    std.Io.Dir.deleteFileAbsolute(io, paths.old) catch {};
    return 0;
}

test "update: asset name for the host target" {
    try std.testing.expect(assetName() != null);
}

test "update: asset names are platform specific" {
    const b = @import("builtin");
    const name = assetName().?;
    switch (b.os.tag) {
        .windows => try std.testing.expect(std.mem.endsWith(u8, name, ".zip")),
        .linux => try std.testing.expect(std.mem.endsWith(u8, name, ".tar.gz")),
        else => unreachable,
    }
}
