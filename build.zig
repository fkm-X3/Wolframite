const std = @import("std");
const builtin = @import("builtin");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("Wolframite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const tungsten_mod = b.addModule("Tungsten", .{
        .root_source_file = b.path("libs/backend/src/root.zig"),
        .target = target,
    });

    const compiler_mod = b.addModule("compiler", .{
        .root_source_file = b.path("compiler/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "Tungsten", .module = tungsten_mod },
        },
    });

    // Commit SHA baked into ore, used by `ore update --check` to decide
    // whether a newer dev build is available. Pass `-Dgit-sha=$(git rev-parse HEAD)`.
    const ore_build_options = b.addOptions();
    ore_build_options.addOption(
        []const u8,
        "git_sha",
        b.option([]const u8, "git-sha", "git commit SHA to embed in ore") orelse "",
    );
    const ore_build_options_mod = ore_build_options.createModule();

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.

    // Progress messages: every artifact's compile step depends on
    // `build_start`, so this is guaranteed to print before any compilation
    // begins.
    const build_start = addPrintStep(b, "print build start", "building Wolframite toolchain ...", &.{});
    // NOTE: this std.debug.print only runs on a fresh build configuration.
    // Zig 0.17 caches build() by build.zig content hash, so on warm-cache
    // repeat invocations (e.g. `zig build test` twice in a row) nothing is
    // printed. The old makeFn/per-step-execution printing was removed in
    // 0.17 and has no replacement API. Re-implement once the project is
    // self-hosting and controls its own build runner.
    // std.debug.print("[wolframite] building Wolframite toolchain ...\n", .{});

    const exe = b.addExecutable(.{
        .name = "Wolframite",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                .{ .name = "Wolframite", .module = mod },
                .{ .name = "compiler", .module = compiler_mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // ore — the Wolframite package manager CLI. It drives the same compiler
    // pipeline as the library, so it imports both the `compiler` module and
    // the Tungsten backend.
    const ore_exe = b.addExecutable(.{
        .name = "ore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ore/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compiler", .module = compiler_mod },
                .{ .name = "Tungsten", .module = tungsten_mod },
                .{ .name = "build_options", .module = ore_build_options_mod },
            },
        }),
    });
    b.installArtifact(ore_exe);

    // wfr_std — the Wolframite runtime library. Prelude calls such as `print`
    // lower to extern calls against this archive, which `ore` links in
    // alongside the program's assembly. It is installed to `zig-out/lib`, which
    // is where `src/ore/link.zig` looks for it.
    //
    // The runtime must not link libc: it talks to the kernel directly (kernel32
    // on Windows, raw syscalls on Linux), so `.link_libc` stays false here.
    const wfr_std_mod = b.createModule(.{
        .root_source_file = b.path("libs/std/src/std.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    const wfr_std_lib = b.addLibrary(.{
        .name = "wfr_std",
        .linkage = .static,
        .root_module = wfr_std_mod,
    });
    b.installArtifact(wfr_std_lib);

    // Gate every artifact's compile step on the build-start message so the
    // message is guaranteed to print before any compilation begins.
    exe.step.dependOn(build_start);
    ore_exe.step.dependOn(build_start);
    wfr_std_lib.step.dependOn(build_start);

    const run_ore_cmd = b.addRunArtifact(ore_exe);
    run_ore_cmd.step.dependOn(b.getInstallStep());
    const ore_step = b.step("ore", "Run the ore CLI");
    ore_step.dependOn(&run_ore_cmd.step);
    run_ore_cmd.addPassthruArgs();

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // Pass through any arguments provided after `--` on the `zig build` CLI
    // (e.g. `zig build run -- arg1 arg2`).
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Compiler module tests
    const compiler_tests = b.addTest(.{
        .root_module = compiler_mod,
    });
    const run_compiler_tests = b.addRunArtifact(compiler_tests);

    // Backend (Tungsten) module tests
    const backend_tests = b.addTest(.{
        .root_module = tungsten_mod,
    });
    const run_backend_tests = b.addRunArtifact(backend_tests);

    // ore CLI module tests
    const ore_tests = b.addTest(.{
        .root_module = ore_exe.root_module,
    });
    const run_ore_tests = b.addRunArtifact(ore_tests);

    // Printed once, before any suite starts: every test run step below
    // depends on it.
    const tests_start = addPrintStep(b, "print tests start", "running tests ...", &.{});
    // std.debug.print("[wolframite] running tests ...\n", .{});  // see NOTE above
    for ([_]*std.Build.Step{
        &run_mod_tests.step,
        &run_exe_tests.step,
        &run_compiler_tests.step,
        &run_backend_tests.step,
        &run_ore_tests.step,
    }) |suite_run| suite_run.dependOn(tests_start);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_compiler_tests.step);
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_ore_tests.step);

    // "Compiler tests passed" is printed only after the compiler suite has
    // succeeded.
    const compiler_tests_done = addPrintStep(b, "print compiler tests done", "compiler tests passed", &.{&run_compiler_tests.step});
    // std.debug.print("[wolframite] compiler tests passed\n", .{});  // see NOTE above
    const test_compiler_step = b.step("test-compiler", "Run compiler tests");
    test_compiler_step.dependOn(compiler_tests_done);

    // Wolframite runtime tests
    const std_tests = b.addTest(.{
        .root_module = wfr_std_mod,
    });
    const run_std_tests = b.addRunArtifact(std_tests);
    run_std_tests.step.dependOn(tests_start);
    test_step.dependOn(&run_std_tests.step);

    const std_tests_done = addPrintStep(b, "print std tests done", "runtime tests passed", &.{&run_std_tests.step});
    // std.debug.print("[wolframite] runtime tests passed\n", .{});  // see NOTE above
    const test_std_step = b.step("test-std", "Run Wolframite runtime tests");
    test_std_step.dependOn(std_tests_done);

    // "All tests passed" is printed only once every suite has succeeded.
    const all_tests_done = addPrintStep(b, "print tests done", "all tests passed", &.{
        &run_mod_tests.step,
        &run_exe_tests.step,
        &run_compiler_tests.step,
        &run_backend_tests.step,
        &run_ore_tests.step,
        &run_std_tests.step,
    });
    // std.debug.print("[wolframite] all tests passed\n", .{});  // see NOTE above
    test_step.dependOn(all_tests_done);

    // `zig build` (no arguments) runs this wrapper: it installs everything and
    // then prints a success message that can only appear if the whole chain
    // succeeded.
    const build_done = addPrintStep(b, "print build done", "build succeeded (artifacts in zig-out)", &.{});
    // std.debug.print("[wolframite] build succeeded (artifacts in zig-out)\n", .{});  // see NOTE above
    build_done.dependOn(b.getInstallStep());
    const build_step = b.step("build", "Build everything (default)");
    build_step.dependOn(build_done);
    b.default_step = build_step;

    // Compiles the toolchain and installs it to the install directory:
    // `%USERPROFILE%\wolframite\bin` (ore/Wolframite) and `%USERPROFILE%\wolframite\lib`
    // (wfr_std) on Windows, `/usr/local/bin` + `/usr/local/wolframite/lib` on Linux.
    const install_compiler_step = b.step("install-compiler", "Install Wolframite, ore, and the wfr_std runtime");
    addInstallCompilerStep(install_compiler_step, &.{ exe, ore_exe }, wfr_std_lib);
    // std.debug.print("[wolframite] toolchain installed\n", .{});  // see NOTE above

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// Creates a step that prints a one-line progress message when it runs. If
/// `suites` is non-empty, the message additionally reports the combined number
/// of tests that passed, and the step only runs after all of them succeeded.
fn addPrintStep(
    b: *std.Build,
    name: []const u8,
    text: []const u8,
    suites: []const *std.Build.Step,
) *std.Build.Step {
    const step = b.step(name, text);
    for (suites) |suite| step.dependOn(suite);
    return step;
}

/// Compiles `bin_artifacts` and installs the emitted binaries into the platform's
/// install directory:
/// * Windows: `<%USERPROFILE%>\wolframite\bin` (ore/Wolframite) and
///   `<%USERPROFILE%>\wolframite\lib` (wfr_std) (`%HOME%` is used when set)
/// * Linux: `/usr/local/wolframite/bin` + `/usr/local/wolframite/lib`, falling back to
///   `$HOME/wolframite/bin` + `$HOME/wolframite/lib` when those locations cannot
///   be written to (e.g. running unprivileged)
///
/// `lib_artifact`, when provided, is installed into the `lib` directory next to
/// `bin` so `ore` (which resolves `<exedir>/../lib`) can find `wfr_std`.
///
/// Returns the step performing the installation; wire it up with
/// `step.dependOn(...)`.
fn addInstallCompilerStep(
    install_step: *std.Build.Step,
    bin_artifacts: []const *std.Build.Step.Compile,
    lib_artifact: ?*std.Build.Step.Compile,
) void {
    // Requesting the emitted binaries is what pulls the compilation of each
    // artifact into the graph.
    for (bin_artifacts) |artifact| {
        artifact.getEmittedBin().addStepDependencies(&install_step.*);
    }
    if (lib_artifact) |lib| {
        lib.getEmittedBin().addStepDependencies(&install_step.*);
    }
}


