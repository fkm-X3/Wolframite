//! Ferro — type surface, error sets, and parsing helpers.
//!
//! This module holds the shared type definitions (Target, ObjectFormat,
//! LinkOptions, LinkDescription, Symbol, Relocation, RelocKind, Section,
//! Object, ResolvedSymbols, ImportThunk, MergedImage), the LinkError /
//! LinkDescriptionError sets, and the target/subsystem parsing functions.
//! It intentionally does NOT import any other ferro submodule, so every
//! submodule can import this one without cycles.

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
// Link description — the Wolframite-facing input to Ferro
// ============================================================================

/// The Wolframite-facing link description, parsed from a Wolframite source
/// module compiled through the normal compiler pipeline (lexer → parser →
/// resolver → typecheck → lower → Tungsten IR). Ferro turns this into the
/// `linkObject` arguments below.
///
/// Fields are string slices borrowed from the compiler arena; they must not
/// outlive it.
pub const LinkDescription = struct {
    target: []const u8,      // "linux" | "windows"
    output: []const u8,      // executable output path
    entry: []const u8,       // entry symbol (default "_main")
    subsystem: []const u8,   // "console" | "gui" (windows only)
    runtime_lib: []const u8, // path to the wfr_std archive
    input: []const u8,       // program object file to link
    debug: bool,
};

/// Errors raised while parsing or validating a `LinkDescription`.
pub const LinkDescriptionError = error{
    /// `target` was not "linux" or "windows".
    InvalidTarget,
    /// `subsystem` was not "console" or "gui".
    InvalidSubsystem,
    /// A required link field was missing or not a string literal.
    MissingField,
};

/// Parse `s` ("linux" | "windows", case-insensitive) into a `Target`.
pub fn parseTarget(s: []const u8) LinkDescriptionError !Target {
    if (std.ascii.eqlIgnoreCase(s, "linux")) return .linux_x86_64;
    if (std.ascii.eqlIgnoreCase(s, "windows")) return .windows_x86_64;
    return error.InvalidTarget;
}

/// Parse `s` ("console" | "gui", case-insensitive) into a `Subsystem`.
pub fn parseSubsystem(s: []const u8) LinkDescriptionError !Subsystem {
    if (std.ascii.eqlIgnoreCase(s, "console")) return .console;
    if (std.ascii.eqlIgnoreCase(s, "gui")) return .gui;
    return error.InvalidSubsystem;
}

/// Convert a `LinkDescription` into validated `LinkOptions`. The object path,
/// runtime lib, output path, and entry symbol pass through verbatim; `target`
/// and `subsystem` are parsed from their string forms here.
///
/// This is the "compile Wolframite → feed Ferro" mapping: the compiler fills a
/// `LinkDescription` from source and Ferro turns it into `linkObject` args.
pub fn linkOptionsFromDescription(desc: LinkDescription) LinkDescriptionError !LinkOptions {
    const target = try parseTarget(desc.target);
    const subsystem = try parseSubsystem(desc.subsystem);
    return .{
        .target = target,
        .entry_symbol = desc.entry,
        .subsystem = subsystem,
        .debug = desc.debug,
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

pub const Kernel32Imports = [_][]const u8{
    "GetStdHandle",
    "WriteFile",
    "ReadFile",
    "GetLastError",
    "ExitProcess",
    "CreateFileW",
    "AllocConsole",
};

/// Returns true when `name` is a Windows kernel32 import that should be
/// resolved via the PE import directory rather than reported as undefined.
pub fn isKernel32Import(name: []const u8) bool {
    for (Kernel32Imports) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

// ============================================================================
// Parsed-object structures
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
    /// Section index the relocation applies to (1 = .text, 2 = .data, matching
    /// the codegen/`ObjectInput` convention; section 0 is undefined/null).
    section_idx: u16,
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

/// A section recorded in an object file. `content` borrows from `Object.file_bytes`
/// and is empty for `SHT_NOBITS` / uninitialized sections (no file bytes).
pub const Section = struct {
    name: []const u8,
    /// File offset of the section's raw content.
    offset: u64,
    /// Size of the section's raw content (0 for NOBITS).
    size: u64,
    /// Section flags (ELF `sh_flags` or COFF `characteristics`).
    flags: u64,
    /// ELF `sh_type` or COFF section characteristics.
    type_: u32,
    content: []const u8,
};

/// The parsed contents of a relocatable object: sections, symbols,
/// relocations. Populated by the object reader. All slices borrow from the
/// owned `file_bytes` buffer, freed by `deinit`.
pub const Object = struct {
    path: []const u8,
    format: ObjectFormat,
    /// Owned buffer that all section contents and symbol/relocation name
    /// slices borrow from.
    file_bytes: []u8,
    sections: std.ArrayList(Section),
    symbols: std.ArrayList(Symbol),
    relocations: std.ArrayList(Relocation),

    pub fn deinit(self: *Object, gpa: Allocator) void {
        gpa.free(self.file_bytes);
        self.sections.deinit(gpa);
        self.symbols.deinit(gpa);
        self.relocations.deinit(gpa);
    }
};

/// A symbol resolved against an object file: the section it lives in and its
/// offset within that section.
pub const ResolvedSymbol = struct {
    section: []const u8,
    value: u64,
};

/// Result of symbol resolution: the undefined symbols that must be satisfied
/// by the runtime archive, plus a map from undefined symbol name to the
/// defining archive symbol once resolved.
pub const ResolvedSymbols = struct {
    undefined: std.ArrayList([]const u8),
    /// Undefined program symbols resolved against the runtime archive:
    /// symbol name → where it lives in the runtime object.
    resolved: std.StringHashMap(ResolvedSymbol),

    pub fn deinit(self: *ResolvedSymbols, gpa: Allocator) void {
        self.undefined.deinit(gpa);
        self.resolved.deinit();
    }
};

pub const ImportThunk = struct {
    name: []const u8,
    rva: u64,
    /// Merged-text address of the thunk in `.text`.
    thunk_addr: u64,
    /// Merged-data address of the IAT slot for this import.
    iat_slot_addr: u64,
    /// Merged-data address of the `IMAGE_IMPORT_BY_NAME` entry.
    name_entry_addr: u64,
};

/// Relocations applied and sections merged into output sections.
///
/// `text` and `data` are owned buffers (allocated with `gpa`) holding the
/// merged `.text` and `.data` contents (program object first, then runtime
/// object). `bss_size` is the merged `.bss` size (no file bytes). `symbols`
/// maps each defined symbol name to its final address in the merged image,
/// used by the executable writer to wire the entry point.
pub const MergedImage = struct {
    text: []u8,
    data: []u8,
    bss_size: u64,
    symbols: std.StringHashMap(ResolvedSymbol),
    import_thunks: std.ArrayList(ImportThunk),
    /// Merged-data address of the import directory descriptor (0 if none).
    import_desc_addr: u64,
    /// Size in bytes of the import directory (descriptors incl. terminator).
    import_desc_size: u64,

    pub fn deinit(self: *MergedImage, gpa: Allocator) void {
        for (self.import_thunks.items) |thunk| gpa.free(thunk.name);
        gpa.free(self.text);
        gpa.free(self.data);
        self.symbols.deinit();
        self.import_thunks.deinit(gpa);
    }
};
