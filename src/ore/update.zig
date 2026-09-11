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
pub fn assetName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "ore-windows-x86_64.exe",
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "ore-linux-x86_64",
            else => null,
        },
        else => null,
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

    const size = if (builtin.os.tag == .windows)
        try stageForSwap(gpa, io, &client, url)
    else
        try swapInPlace(gpa, io, &client, url);

    return .{
        .url = url,
        .size = size,
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
fn siblingPaths(gpa: Allocator, exe_path: []const u8) !struct {
    dir: []const u8,
    staged: []u8,
    updater: []u8,
    old: []u8,
} {
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

/// Swap in-place: allowed on POSIX, where a running executable may be
/// renamed. The running image keeps executing; the next launch is the new one.
fn swapInPlace(gpa: Allocator, io: Io, client: *http.Client, url: []const u8) UpdateError!u64 {
    const exe_path = try std.process.executablePathAlloc(io, gpa);
    const paths = try siblingPaths(gpa, exe_path);
    const size = try downloadTo(io, client, url, paths.staged);

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

    return size;
}

/// Stage the update for a helper process: download to `<exe>.staged`, copy
/// the current binary to `<exe>.updater`, and spawn it with `--apply-update`.
fn stageForSwap(gpa: Allocator, io: Io, client: *http.Client, url: []const u8) UpdateError!u64 {
    const exe_path = try std.process.executablePathAlloc(io, gpa);
    const paths = try siblingPaths(gpa, exe_path);

    // The updater from a previous update may still be lying around.
    std.Io.Dir.deleteFileAbsolute(io, paths.updater) catch {};
    const size = try downloadTo(io, client, url, paths.staged);
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

    return size;
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
        .windows => try std.testing.expect(std.mem.endsWith(u8, name, ".exe")),
        .linux => try std.testing.expect(!std.mem.endsWith(u8, name, ".exe")),
        else => unreachable,
    }
}
