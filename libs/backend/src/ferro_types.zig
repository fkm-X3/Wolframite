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
    elf64, // Linux: ET_REL ELF64 object, `.o`
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

// ============================================================================
// Target triples
// ============================================================================

/// A target triple split into its components.
///
/// Wolframite's canonical triples are `x86_64-unknown-linux` and
/// `x86_64-microsoft-windows`. The grammar is `arch[-vendor]-os[-abi]`, but
/// the spelling deliberately diverges from GCC/LLVM: the runtime is libc-free,
/// so there is no ABI component (no `gnu`/`musl`/`msvc`), and the Windows
/// vendor is `microsoft` rather than `pc`. Foreign spellings such as
/// `x86_64-pc-windows-msvc` are accepted and map to the same two targets.
///
/// Component slices borrow from the parsed string and keep their original
/// case; matching downstream is case-insensitive.
pub const Triple = struct {
    /// CPU architecture. Tungsten emits x86_64 machine code, so only
    /// `x86_64` (alias `amd64`) is accepted.
    arch: []const u8,
    /// Vendor component (`pc`, `unknown`, `w64`, ...). Accepted but ignored.
    vendor: []const u8,
    /// Operating-system component: `linux`, or a Windows alias (`windows`,
    /// `mingw32`, `mingw`).
    os: []const u8,
    /// ABI / environment suffix (`gnu`, `musl`, `msvc`, ...). Accepted but
    /// ignored: Ferro emits one object flavor per platform.
    abi: []const u8 = "",

    /// Map this triple to the `Target` Ferro links for.
    ///
    /// Returns `LinkDescriptionError.InvalidTarget` when the architecture is
    /// not x86_64 or the OS is not Linux/Windows — the only platforms the
    /// object writers and Ferro support (see `docs/adr/adr_ferro_linker.md`).
    pub fn target(self: Triple) LinkDescriptionError!Target {
        if (!isX86_64Arch(self.arch)) return error.InvalidTarget;
        if (isWindowsOs(self.os)) return .windows_x86_64;
        if (isLinuxOs(self.os)) return .linux_x86_64;
        return error.InvalidTarget;
    }
};

/// Parse a target triple (`arch[-vendor]-os[-abi]`) into its components. The
/// component slices borrow from `s`.
///
/// The OS component is located by name rather than by position, so both the
/// canonical form (`x86_64-unknown-linux`: arch-vendor-os) and the shorter
/// two-part form (`x86_64-linux`: arch-os) parse to the same result.
/// Components after the ABI are accepted and ignored.
pub fn parseTriple(s: []const u8) LinkDescriptionError!Triple {
    var parts: [8][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, s, '-');
    while (it.next()) |part| {
        if (part.len == 0) return error.InvalidTarget; // empty component
        if (count == parts.len) return error.InvalidTarget; // too many components
        parts[count] = part;
        count += 1;
    }
    if (count < 2) return error.InvalidTarget;

    // The architecture is the first component; find the OS among the rest.
    var os_idx: ?usize = null;
    for (parts[1..count], 1..) |part, i| {
        if (isOsName(part)) {
            os_idx = i;
            break;
        }
    }
    const os_i = os_idx orelse return error.InvalidTarget;

    return .{
        .arch = parts[0],
        .vendor = if (os_i > 1) parts[1] else "unknown",
        .os = parts[os_i],
        .abi = if (count > os_i + 1) parts[os_i + 1] else "",
    };
}

fn eqlAnyIgnoreCase(s: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(s, name)) return true;
    }
    return false;
}

fn isX86_64Arch(s: []const u8) bool {
    return eqlAnyIgnoreCase(s, &.{ "x86_64", "amd64" });
}

fn isOsName(s: []const u8) bool {
    return isLinuxOs(s) or isWindowsOs(s);
}

fn isLinuxOs(s: []const u8) bool {
    return eqlAnyIgnoreCase(s, &.{"linux"});
}

fn isWindowsOs(s: []const u8) bool {
    return eqlAnyIgnoreCase(s, &.{ "windows", "mingw32", "mingw" });
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
    /// When true, `linkObject` prints the merged image (section sizes,
    /// symbol addresses, relocations before/after application) to stderr
    /// before writing the executable. A debugging aid for linker issues
    /// such as wrong symbol addresses or displacements near the i32 limit.
    dump: bool,
};

/// Convenient defaults for `LinkOptions`. The caller must always supply
/// `target` explicitly — Ferro does not derive it from the host OS.
pub fn defaultLinkOptions(target: Target) LinkOptions {
    return .{
        .target = target,
        .entry_symbol = "_main",
        .subsystem = .console,
        .debug = false,
        .dump = false,
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
    /// `"linux"`, `"windows"`, or an x86_64 target triple — canonical forms
    /// are `"x86_64-unknown-linux"` and `"x86_64-microsoft-windows"` — parsed
    /// with `parseTarget`.
    target: []const u8,
    output: []const u8, // executable output path
    entry: []const u8, // entry symbol (default "_main")
    subsystem: []const u8, // "console" | "gui" (windows only)
    runtime_lib: []const u8, // path to the wfr_std archive
    input: []const u8, // program object file to link
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

/// Parse `s` into a `Target`.
///
/// Accepted forms, all case-insensitive:
///
///   - the platform names `linux` and `windows`;
///   - the canonical triples `x86_64-unknown-linux` and
///     `x86_64-microsoft-windows` (see `Triple` for why the spelling differs
///     from GCC/LLVM);
///   - tolerated foreign/shorter triples such as `x86_64-pc-windows-msvc`,
///     `x86_64-unknown-linux-gnu`, or `x86_64-linux`, which map to the same
///     two targets. The architecture must be `x86_64` (alias `amd64`) and the
///     OS component must be Linux or Windows; vendor/ABI components are
///     accepted but ignored (see `Triple.target`).
pub fn parseTarget(s: []const u8) LinkDescriptionError!Target {
    if (std.ascii.eqlIgnoreCase(s, "linux")) return .linux_x86_64;
    if (std.ascii.eqlIgnoreCase(s, "windows")) return .windows_x86_64;
    // Anything containing '-' is parsed as a target triple.
    if (std.mem.indexOfScalar(u8, s, '-') != null) {
        const triple = try parseTriple(s);
        return triple.target();
    }
    return error.InvalidTarget;
}

/// Parse `s` ("console" | "gui", case-insensitive) into a `Subsystem`.
pub fn parseSubsystem(s: []const u8) LinkDescriptionError!Subsystem {
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
pub fn linkOptionsFromDescription(desc: LinkDescription) LinkDescriptionError!LinkOptions {
    const target = try parseTarget(desc.target);
    const subsystem = try parseSubsystem(desc.subsystem);
    return .{
        .target = target,
        .entry_symbol = desc.entry,
        .subsystem = subsystem,
        .debug = desc.debug,
        .dump = false,
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
    "VirtualAlloc",
    "CreateFileW",
    "AllocConsole",
    "GetProcessHeap",
    "HeapAlloc",
};

/// The DLL that a Windows OS import resolves against.
pub const OsImportDll = enum {
    kernel32,
    ntdll,

    /// The DLL name as it must appear in the PE import descriptor.
    pub fn dllName(self: OsImportDll) []const u8 {
        return switch (self) {
            .kernel32 => "kernel32.dll",
            .ntdll => "ntdll.dll",
        };
    }
};

/// The fixed emission order of import DLLs in the PE import directory
/// (deterministic output regardless of undefined-symbol discovery order).
pub const os_import_dll_order = [_]OsImportDll{ .kernel32, .ntdll };

/// Size of the synthesized Windows entry stub (`call _main; ret`) that
/// `writeExecutablePe` appends to merged `.text` before `.data` begins.
/// Ferro's relocation model (the `.data` VA gap and import-table RVAs) must
/// agree with that layout, so the size lives here for both to use.
pub const pe_entry_stub_size: u64 = 6;

/// Classify an undefined symbol that must resolve through the platform import
/// table instead of the runtime archive. Returns null when `name` is not an
/// OS import; on Linux this is always null (the runtime talks to the kernel
/// via raw syscalls, so any undefined symbol there is a link error).
///
/// Two DLLs are recognized on Windows:
///   - kernel32: the exact names in `Kernel32Imports` — the classic Win32
///     console/process entry points the runtime calls directly;
///   - ntdll: `Nt*`/`Zw*`/`Rtl*` prefixes, which is what the runtime's
///     Zig-std portions reference (file I/O, heap, activation contexts,
///     unwinding). ntdll is the system provider of those names — including
///     the few `Rtl*` exports kernel32 also forwards — so prefix
///     classification resolves correctly for both.
pub fn osImportDll(name: []const u8, target: Target) ?OsImportDll {
    if (target == .linux_x86_64) return null;
    for (Kernel32Imports) |k| {
        if (std.mem.eql(u8, name, k)) return .kernel32;
    }
    if (std.mem.startsWith(u8, name, "Nt") or
        std.mem.startsWith(u8, name, "Zw") or
        std.mem.startsWith(u8, name, "Rtl"))
    {
        return .ntdll;
    }
    return null;
}

/// Target-aware predicate: on Windows, `name` is an OS import resolved via
/// the PE import directory; on Linux there are no such imports (the runtime
/// talks to the OS via raw syscalls), so this always returns false for
/// `.linux_x86_64`.
pub fn isOsImport(name: []const u8, target: Target) bool {
    return osImportDll(name, target) != null;
}

/// Backwards-compatible alias for the Windows-only predicate.
pub fn isKernel32Import(name: []const u8) bool {
    return isOsImport(name, .windows_x86_64);
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
    /// Section index the relocation applies to (1 = .text, 2 = .data,
    /// 3 = TLS initialization data, matching the codegen/`ObjectInput`
    /// convention for the first two; section 0 is undefined/null).
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
    /// Absolute 32-bit (signed): `S + A` (R_X86_64_32 / R_X86_64_32S).
    abs32,
    /// Byte offset within the final TLS template (IMAGE_REL_AMD64_SECREL).
    secrel32,
    /// Signed offset from the x86_64 thread pointer (R_X86_64_TPOFF32).
    tpoff32,
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
    /// Required byte alignment. COFF leaves this unspecified for ordinary
    /// Zig sections, so the reader uses 1 there; ELF preserves sh_addralign.
    alignment: u64 = 1,
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
    /// Buffers owned by archive-merged objects (merged `.text`/`.data`/TLS).
    /// `null` for directly-read objects, whose section contents borrow from
    /// `file_bytes`.
    owned_text: ?[]u8 = null,
    owned_data: ?[]u8 = null,
    owned_tls: ?[]u8 = null,
    /// When true, symbol and relocation names were duplicated and must be freed
    /// by `deinit` (archive-merged objects). Directly-read objects borrow them
    /// from `file_bytes`.
    owns_symbol_names: bool = false,

    pub fn deinit(self: *Object, gpa: Allocator) void {
        if (self.owns_symbol_names) {
            for (self.symbols.items) |sym| gpa.free(sym.name);
            for (self.relocations.items) |rel| gpa.free(rel.symbol);
        }
        if (self.owned_text) |buf| gpa.free(buf);
        if (self.owned_data) |buf| gpa.free(buf);
        if (self.owned_tls) |buf| gpa.free(buf);
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
    /// Initialized per-thread template. TLS symbols retain offsets into this
    /// block rather than process-global virtual addresses.
    tls: []u8 = &[_]u8{},
    /// Zero-initialized bytes following `tls` in every thread's TLS block.
    tls_zero_fill_size: u64 = 0,
    /// Alignment of the complete TLS block (PT_TLS p_align on ELF).
    tls_alignment: u64 = 8,
    /// Offset of the synthesized PE `_tls_index` cell within `data`.
    tls_index_offset: u64 = 0,
    symbols: std.StringHashMap(ResolvedSymbol),
    import_thunks: std.ArrayList(ImportThunk),
    /// Merged-data address of the import directory descriptor (0 if none).
    import_desc_addr: u64,
    /// Size in bytes of the import directory (descriptors incl. terminator).
    import_desc_size: u64,
    /// Offsets (within merged .text) of R_X86_64_32/S absolute 32-bit reloc sites.
    abs32_sites: std.ArrayList(u64),
    /// Offsets (within merged .data) of R_X86_64_64 absolute 64-bit reloc sites.
    addr64_sites: std.ArrayList(u64),

    pub fn deinit(self: *MergedImage, gpa: Allocator) void {
        for (self.import_thunks.items) |thunk| gpa.free(thunk.name);
        gpa.free(self.text);
        gpa.free(self.data);
        if (self.tls.len > 0) gpa.free(self.tls);
        self.symbols.deinit();
        self.import_thunks.deinit(gpa);
        self.abs32_sites.deinit(gpa);
        self.addr64_sites.deinit(gpa);
    }
};

const testing = std.testing;

test "osImportDll classifies kernel32 whitelist names exactly" {
    try testing.expectEqual(OsImportDll.kernel32, osImportDll("GetStdHandle", .windows_x86_64).?);
    try testing.expectEqual(OsImportDll.kernel32, osImportDll("WriteFile", .windows_x86_64).?);
    try testing.expectEqual(OsImportDll.kernel32, osImportDll("ExitProcess", .windows_x86_64).?);
    // Not on the whitelist: even an Nt-like spelling of a kernel32 name is
    // only an import if it is listed or matches an ntdll prefix.
    try testing.expect(osImportDll("WriteFileEx", .windows_x86_64) == null);
}

test "osImportDll classifies ntdll prefixes (Nt*/Zw*/Rtl*)" {
    try testing.expectEqual(OsImportDll.ntdll, osImportDll("NtWriteFile", .windows_x86_64).?);
    try testing.expectEqual(OsImportDll.ntdll, osImportDll("ZwClose", .windows_x86_64).?);
    try testing.expectEqual(OsImportDll.ntdll, osImportDll("RtlFreeHeap", .windows_x86_64).?);
    try testing.expectEqual(OsImportDll.ntdll, osImportDll("RtlExitUserProcess", .windows_x86_64).?);
}

test "osImportDll returns null for non-import names and on Linux" {
    try testing.expect(osImportDll("wfr_std_print", .windows_x86_64) == null);
    try testing.expect(osImportDll("malloc", .windows_x86_64) == null);
    try testing.expect(osImportDll("GetStdHandle", .linux_x86_64) == null);
    try testing.expect(osImportDll("NtWriteFile", .linux_x86_64) == null);
    try testing.expect(isOsImport("GetStdHandle", .windows_x86_64));
    try testing.expect(!isOsImport("GetStdHandle", .linux_x86_64));
    try testing.expectEqualStrings("kernel32.dll", OsImportDll.kernel32.dllName());
    try testing.expectEqualStrings("ntdll.dll", OsImportDll.ntdll.dllName());
}
