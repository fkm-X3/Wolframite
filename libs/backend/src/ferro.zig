//! Ferro — the Ferrotungsten linker.
//!
//! Ferro consumes Tungsten-emitted object files (ELF64 on Linux, PE/COFF on
//! Windows) plus the Wolframite runtime archive and produces a runnable
//! executable. It replaces the `nasm` + `zig cc` chain that `ore` used before
//! object emission existed.
//!
//! This file freezes the linker interface: the `linkObject` entry point, the
//! `Target` / `ObjectFormat` mapping, the `LinkOptions` surface, and the
//! `LinkError` set. The object reader, symbol resolver, relocation applier,
//! and executable writer are stubs here and are implemented later.
//!
//! See `libs/backend/docs/adr/adr_ferro_linker.md` for the decision record.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Target + object format
// ============================================================================

/// The target platform Ferro links for. x86_64 only.
///
/// The compiler decides the target and passes it to Ferro via
/// `LinkOptions.target`. Ferro never guesses the platform from the host it
/// runs on — link semantics are explicit, per `design.md`
/// "Determinism over Magic".
pub const Target = enum(u8) {
    linux_x86_64,
    windows_x86_64,
};

/// The relocatable object format Tungsten emits for a target.
///
/// One format per platform keeps Ferro's reader simple: one reader per
/// format, no cross-format conversion.
pub const ObjectFormat = enum(u8) {
    elf64,   // Linux: ET_REL ELF64 object, `.o`
    pe_coff, // Windows: COFF object, `.obj`
};

/// Map a `Target` to the object format Tungsten must emit for it.
///
/// The compiler consults this to pick the object-emission format and passes
/// the same `Target` to Ferro so link and emission agree.
pub fn objectFormat(target: Target) ObjectFormat {
    return switch (target) {
        .linux_x86_64 => .elf64,
        .windows_x86_64 => .pe_coff,
    };
}

/// The subsystem of a Windows executable. Ignored on Linux; kept in
/// `LinkOptions` so the Wolframite-facing link description can select console
/// vs GUI.
pub const Subsystem = enum(u8) {
    console,
    gui,
};

// ============================================================================
// Link options
// ============================================================================

/// Arguments to `linkObject`.
pub const LinkOptions = struct {
    /// Target platform. Determines the object format read, the entry-point
    /// shim synthesized, and the executable container written (ELF vs PE).
    target: Target,
    /// The symbol the backend names as program entry. Tungsten uses `_main`
    /// (see `docs/adr/adr_object_format.md`); Ferro wires this to the
    /// platform entry point (`_start` on Linux, the CRT entry on Windows).
    entry_symbol: []const u8,
    /// Windows subsystem. Ignored on Linux.
    subsystem: Subsystem,
    /// Emit debug info / keep a PDB next to the executable.
    debug: bool,
};

/// Convenient defaults for `LinkOptions`. The caller must always supply
/// `target` explicitly — Ferro does not derive it from the host OS.
pub fn defaultLinkOptions(target: Target) LinkOptions {
    return .{
        .target = target,
        .entry_symbol = "_main",
        .subsystem = .console,
        .debug = false,
    };
}

// ============================================================================
// Errors
// ============================================================================

pub const LinkError = error{
    /// The input object file does not exist.
    ObjectMissing,
    /// The object file exists but could not be parsed (truncated, bad magic,
    /// unknown format).
    ObjectReadFailed,
    /// The Wolframite runtime archive (`wfr_std`) was not found.
    RuntimeLibMissing,
    /// A symbol referenced by the program object has no definition in the
    /// program object or the runtime archive.
    UndefinedSymbol,
    /// A relocation could not be applied (e.g. PC32 out of range).
    RelocationFailed,
    /// The output executable could not be written.
    WriteFailed,
};

// ============================================================================
// Parsed-object structures (stubs; populated later)
// ============================================================================

/// A symbol recorded in an object file.
pub const Symbol = struct {
    name: []const u8,
    /// Section the symbol is defined in, or null if undefined.
    section: ?[]const u8,
    value: u64, // offset within section; 0 for undefined symbols
    size: u64,
    binding: Binding,
};

pub const Binding = enum(u8) {
    local,
    global,
    weak,
};

/// A relocation record parsed from an object file.
pub const Relocation = struct {
    /// Offset within the section where the relocated bytes live.
    offset: u64,
    symbol: []const u8,
    /// `R_X86_64_PC32` / `IMAGE_REL_AMD64_REL32` or `R_X86_64_64` /
    /// `IMAGE_REL_AMD64_ADDR64` (see `docs/adr/adr_object_format.md`).
    kind: RelocKind,
    /// Addend already present at the relocation site (RELA style; implicit
    /// for PE/COFF where the site bytes are the addend).
    addend: i64,
};

pub const RelocKind = enum(u8) {
    /// PC-relative 32-bit: `S + A - P`, sign-extended to 64.
    pc32,
    /// Absolute 64-bit: `S + A`.
    addr64,
};

/// The parsed contents of a relocatable object: sections, symbols,
/// relocations. Populated by the object reader.
pub const Object = struct {
    path: []const u8,

    pub fn deinit(_: *Object, _: Allocator) void {}
};

/// Result of symbol resolution: the undefined symbols that must be satisfied
/// by the runtime archive, plus a map from undefined symbol name to the
/// defining archive symbol once resolved.
pub const ResolvedSymbols = struct {
    undefined: std.ArrayList([]const u8),

    pub fn deinit(self: *ResolvedSymbols, gpa: Allocator) void {
        self.undefined.deinit(gpa);
    }
};

/// Relocations applied and sections merged into output sections.
pub const MergedImage = struct {
    pub fn deinit(_: *MergedImage, _: Allocator) void {}
};

// ============================================================================
// Stubs (implemented later)
// ============================================================================

/// Read an object file's sections, symbol table, and relocation table.
///
/// Stub: confirms the input file exists, then returns
/// `ObjectReaderUnimplemented` until the reader is implemented.
pub fn readObject(io: std.Io, _: Allocator, path: []const u8) !Object {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.ObjectMissing;
    return error.ObjectReaderUnimplemented;
}

/// Resolve every undefined symbol in `program` against `runtime_lib`.
///
/// Stub: returns `SymbolResolutionUnimplemented`. The real implementation
/// collects defined/undefined symbols from both objects, resolves undefined
/// references, and reports `UndefinedSymbol` with the symbol name for
/// anything still unresolved.
pub fn resolveSymbols(
    _: *Object,
    _: *Object,
    _: []const u8,
    _: Allocator,
) !ResolvedSymbols {
    return error.SymbolResolutionUnimplemented;
}

/// Apply relocations and merge `.text`/`.data`/`.bss` from program object
/// and runtime into output sections.
///
/// Stub: returns `RelocationUnimplemented`.
pub fn applyRelocations(_: *ResolvedSymbols, _: Allocator) !MergedImage {
    return error.RelocationUnimplemented;
}

/// Synthesize the platform entry point and write the final executable.
///
/// Stub: returns `ExecutableWriterUnimplemented`. The real implementation
/// writes an ELF executable (Linux, with program headers / interpreter) or a
/// PE executable (Windows) whose entry calls `options.entry_symbol`.
pub fn writeExecutable(
    _: *MergedImage,
    _: []const u8,
    _: LinkOptions,
    _: Allocator,
    _: std.Io,
) !void {
    return error.ExecutableWriterUnimplemented;
}

/// Link `object_path` (a Tungsten-emitted object) with the Wolframite runtime
/// `runtime_lib` into the executable `exe_path`.
///
/// This is the front-facing Ferro entry point used by `ore` and by any
/// Wolframite code driving the linker directly (`design.md`: link steps are
/// explicit Zig calls, not an `ld` script).
///
/// Steps (implemented later):
///   1. `readObject(object_path)`          — object reader
///   2. `readObject(runtime_lib)`          — object reader
///   3. `resolveSymbols(...)`              — symbol resolution
///   4. `applyRelocations(...)`            — relocation application
///   5. Synthesize entry (`entry_symbol` → platform entry)
///   6. `writeExecutable(...)`             — executable writer
///
/// On success `exe_path` is a runnable x86-64 executable for
/// `options.target`. Returns a `LinkError` on failure.
pub fn linkObject(
    io: std.Io,
    gpa: Allocator,
    object_path: []const u8,
    runtime_lib: []const u8,
    exe_path: []const u8,
    options: LinkOptions,
) !void {
    var object = try readObject(io, gpa, object_path);
    defer object.deinit(gpa);

    var runtime = try readObject(io, gpa, runtime_lib);
    defer runtime.deinit(gpa);

    var resolved = try resolveSymbols(&object, &runtime, options.entry_symbol, gpa);
    defer resolved.deinit(gpa);

    var image = try applyRelocations(&resolved, gpa);
    defer image.deinit(gpa);

    try writeExecutable(&image, exe_path, options, gpa, io);
}

// ============================================================================
// Tests
// ============================================================================

test "objectFormat maps each target to its object format" {
    try std.testing.expectEqual(ObjectFormat.elf64, objectFormat(.linux_x86_64));
    try std.testing.expectEqual(ObjectFormat.pe_coff, objectFormat(.windows_x86_64));
}

test "defaultLinkOptions keeps target explicit and picks _main as entry" {
    const opts = defaultLinkOptions(.windows_x86_64);
    try std.testing.expectEqual(.windows_x86_64, opts.target);
    try std.testing.expectEqualStrings("_main", opts.entry_symbol);
    try std.testing.expectEqual(.console, opts.subsystem);
    try std.testing.expectEqual(false, opts.debug);
}

test "linkObject reports ObjectMissing for a nonexistent object file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const opts = defaultLinkOptions(.linux_x86_64);

    const result = linkObject(
        io,
        gpa,
        "does-not-exist-ferro-test.o",
        "also-does-not-exist.lib",
        "does-not-exist-ferro-test.exe",
        opts,
    );
    if (result) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.ObjectMissing, err);
    }
}

test "readObject reports ObjectMissing before touching the object reader" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const result = readObject(io, gpa, "does-not-exist-ferro-test.o");
    if (result) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.ObjectMissing, err);
    }
}
