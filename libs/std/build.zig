const std = @import("std");

/// Standalone build for the Wolframite runtime library.
///
/// The root `build.zig` also builds this as part of `zig build`, so this file
/// exists for `libs/std` to build and test on its own.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("WfrStd", .{
        .root_source_file = b.path("src/std.zig"),
        .target = target,
        .optimize = optimize,
        // The runtime must never acquire a libc dependency. If a std import
        // ever starts pulling one in, this line is what turns that into a
        // build failure instead of a silent link.
        .link_libc = false,
    });

    // A program links the runtime as a static archive, so this is a library and
    // not an installable executable. Only the exported entry points matter;
    // everything else is inlined or dropped by the optimizer.
    const lib = b.addLibrary(.{
        .name = "wfr_std",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the runtime's tests");
    test_step.dependOn(&run_tests.step);
}
