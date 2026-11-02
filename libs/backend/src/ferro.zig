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

    pub fn deinit(self: *MergedImage, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.data);
        self.symbols.deinit();
    }
};

// ============================================================================
// Stubs (implemented later)
// ============================================================================

/// Read an object file's sections, symbol table, and relocation table.
///
/// The object format (ELF64 or PE/COFF) is detected from the file's magic
/// bytes, so the caller never has to state it explicitly. Returns
/// `ObjectMissing` when the file does not exist and `ObjectReadFailed` when
/// it cannot be parsed.
pub fn readObject(io: std.Io, gpa: Allocator, path: []const u8) !Object {
    var file_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        std.Io.File.OpenError.FileNotFound, std.Io.File.OpenError.AccessDenied => return error.ObjectMissing,
        else => return error.ObjectReadFailed,
    };
    // `file_bytes` is owned by this function. `Object` takes ownership on
    // success; every early error path frees it via the defer below.
    var owned: bool = true;
    defer if (owned) gpa.free(file_bytes);

    if (file_bytes.len < 16) return error.ObjectReadFailed;

    // ELF magic: 0x7f 'E' 'L' 'F'
    if (file_bytes[0] == 0x7f and std.mem.eql(u8, file_bytes[1..4], "ELF")) {
        const obj = try readElfObject(gpa, path, file_bytes);
        owned = false; // ownership transferred to `obj`
        return obj;
    }

    // COFF object files have no magic bytes; they start with the COFF file
    // header whose first field is the machine type. x86-64 = 0x8664.
    if (file_bytes.len >= 2 and readU16(file_bytes, 0) == 0x8664) {
        const obj = try readCoffObject(gpa, path, file_bytes);
        owned = false; // ownership transferred to `obj`
        return obj;
    }

    return error.ObjectReadFailed;
}

// ============================================================================
// ELF64 object reader
// ============================================================================

const ElfClass64: u8 = 2;
const ElfDataLsb: u8 = 1;

const ShtProgbits: u32 = 1;
const ShtSymtab: u32 = 2;
const ShtStrtab: u32 = 3;
const ShtRela: u32 = 4;
const ShtNobits: u32 = 8;

const CoffSectionText: u16 = 1;
const CoffSectionData: u16 = 2;
const CoffSectionBss: u16 = 3;
const CoffSectionUndefined: u16 = 0;

const CoffSymSize: u64 = 18;
const CoffAuxSectionSize: u64 = 18;
const CoffRelocSize: u64 = 10;

const CoffRelocAddr64: u16 = 1; // IMAGE_REL_AMD64_ADDR64
const CoffRelocRel32: u16 = 4;  // IMAGE_REL_AMD64_REL32

const StBindingLocal: u8 = 0;
const StBindingGlobal: u8 = 1;
const StBindingWeak: u8 = 2;

const RelX86_64_64: u32 = 1;
const RelX86_64_PC32: u32 = 2;

fn readU16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return @as(u32, bytes[off])
        | (@as(u32, bytes[off + 1]) << 8)
        | (@as(u32, bytes[off + 2]) << 16)
        | (@as(u32, bytes[off + 3]) << 24);
}

fn readU64(bytes: []const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        v |= @as(u64, bytes[off + @as(usize, i)]) << i * 8;
    }
    return v;
}

fn readI64(bytes: []const u8, off: usize) i64 {
    return @bitCast(readU64(bytes, off));
}

fn readElfObject(gpa: Allocator, path: []const u8, file_bytes: []u8) !Object {
    if (file_bytes.len < 64) return error.ObjectReadFailed;
    if (file_bytes[4] != ElfClass64) return error.ObjectReadFailed;
    if (file_bytes[5] != ElfDataLsb) return error.ObjectReadFailed;

    const e_shoff = readU64(file_bytes, 40);
    const e_shentsize = @as(u64, @intCast(readU16(file_bytes, 58)));
    const e_shnum = @as(u64, @intCast(readU16(file_bytes, 60)));
    const e_shstrndx = @as(u64, @intCast(readU16(file_bytes, 62)));

    if (e_shentsize != 64) return error.ObjectReadFailed;
    if (e_shoff + e_shnum * e_shentsize > @as(u64, file_bytes.len)) return error.ObjectReadFailed;

    var obj = Object{
        .path = path,
        .format = .elf64,
        .file_bytes = file_bytes,
        .sections = .empty,
        .symbols = .empty,
        .relocations = .empty,
    };
    errdefer obj.deinit(gpa);

    // Read all section headers into a temporary list.
    var sec_hdrs: std.ArrayList(struct {
        name_off: u32,
        type_: u32,
        flags: u64,
        offset: u64,
        size: u64,
        link: u32,
        info: u32,
        addralign: u64,
        entsize: u64,
    }) = .empty;
    defer sec_hdrs.deinit(gpa);

    var i: u64 = 0;
    while (i < e_shnum) : (i += 1) {
        const off = e_shoff + i * 64;
        try sec_hdrs.append(gpa, .{
            .name_off = readU32(file_bytes, @intCast(off + 0)),
            .type_ = readU32(file_bytes, @intCast(off + 4)),
            .flags = readU64(file_bytes, @intCast(off + 8)),
            .offset = readU64(file_bytes, @intCast(off + 24)),
            .size = readU64(file_bytes, @intCast(off + 32)),
            .link = readU32(file_bytes, @intCast(off + 40)),
            .info = readU32(file_bytes, @intCast(off + 44)),
            .addralign = readU64(file_bytes, @intCast(off + 48)),
            .entsize = readU64(file_bytes, @intCast(off + 56)),
        });
    }

    // Read the section name string table.
    if (e_shstrndx >= e_shnum) return error.ObjectReadFailed;
    const shstr = sec_hdrs.items[@intCast(e_shstrndx)];
    if (shstr.offset + shstr.size > @as(u64, file_bytes.len)) return error.ObjectReadFailed;
    const shstrtab = file_bytes[@intCast(shstr.offset)..@intCast(shstr.offset + shstr.size)];

    // Populate sections.
    var si: u64 = 0;
    var nobits: [0]u8 = undefined;
    while (si < e_shnum) : (si += 1) {
        const hdr = sec_hdrs.items[@intCast(si)];
        const content = if (hdr.type_ == ShtNobits) nobits[0..] else file_bytes[@intCast(hdr.offset)..@intCast(hdr.offset + hdr.size)];
        try obj.sections.append(gpa, .{
            .name = cstr(shstrtab, @intCast(hdr.name_off)),
            .offset = hdr.offset,
            .size = hdr.size,
            .flags = hdr.flags,
            .type_ = hdr.type_,
            .content = content,
        });
    }

    // Find symtab and its strtab.
    var symtab_idx: ?usize = null;
    si = 0;
    while (si < e_shnum) : (si += 1) {
        const hdr = sec_hdrs.items[@intCast(si)];
        if (hdr.type_ == ShtSymtab) {
            symtab_idx = @as(usize, si);
        }
    }

    if (symtab_idx != null) {
        const symtab = sec_hdrs.items[symtab_idx.?];
        if (symtab.link >= e_shnum) return error.ObjectReadFailed;
        const strtab_hdr = sec_hdrs.items[@intCast(symtab.link)];
        if (strtab_hdr.offset + strtab_hdr.size > @as(u64, file_bytes.len)) return error.ObjectReadFailed;
        const strtab = file_bytes[@intCast(strtab_hdr.offset)..@intCast(strtab_hdr.offset + strtab_hdr.size)];
        if (symtab.offset + symtab.size > @as(u64, file_bytes.len)) return error.ObjectReadFailed;
        const sym_data = file_bytes[@intCast(symtab.offset)..@intCast(symtab.offset + symtab.size)];

        const sym_count = symtab.size / 24;
        var s: u64 = 0;
        while (s < sym_count) : (s += 1) {
            const soff = s * 24;
            const st_name = readU32(sym_data, @intCast(soff + 0));
            const st_info = sym_data[@intCast(soff + 4)];
            const st_shndx = readU16(sym_data, @intCast(soff + 6));
            const st_value = readU64(sym_data, @intCast(soff + 8));
            const st_size = readU64(sym_data, @intCast(soff + 16));
            const binding: Binding = switch (st_info >> 4) {
                StBindingLocal => .local,
                StBindingGlobal => .global,
                StBindingWeak => .weak,
                else => .local,
            };
            // Symbol 0 is STN_UNDEF (the null symbol) — it has no section.
            // st_shndx == 0 (SHN_UNDEF) means the symbol is undefined.
            const sec_name = if (@as(u64, st_shndx) == 0 or @as(u64, st_shndx) >= e_shnum) null else cstr(shstrtab, sec_hdrs.items[@intCast(st_shndx)].name_off);
            try obj.symbols.append(gpa, .{
                .name = cstr(strtab, @intCast(st_name)),
                .section = sec_name,
                .value = st_value,
                .size = st_size,
                .binding = binding,
            });
        }
    }

    // Relocations: walk all SHT_RELA sections.
    si = 0;
    while (si < e_shnum) : (si += 1) {
        const hdr = sec_hdrs.items[@intCast(si)];
        if (hdr.type_ != ShtRela) continue;
        if (hdr.link >= e_shnum or hdr.info >= e_shnum) return error.ObjectReadFailed;
        const target_sec_idx = @as(usize, @intCast(hdr.info));
        if (hdr.offset + hdr.size > @as(u64, file_bytes.len)) return error.ObjectReadFailed;
        const rela_data = file_bytes[@intCast(hdr.offset)..@intCast(hdr.offset + hdr.size)];
        const rela_count = hdr.size / 24;
        var r: u64 = 0;
        while (r < rela_count) : (r += 1) {
            const roff = r * 24;
            const r_offset = readU64(rela_data, @intCast(roff + 0));
            const r_info = readU64(rela_data, @intCast(roff + 8));
            const r_addend = readI64(rela_data, @intCast(roff + 16));
            const sym_idx = @as(usize, @intCast(r_info >> 32));
            const sym_name = if (sym_idx < obj.symbols.items.len) obj.symbols.items[sym_idx].name else "";
            const kind: RelocKind = switch (@as(u32, @intCast(r_info & 0xFFFF_FFFF))) {
                RelX86_64_PC32 => .pc32,
                RelX86_64_64 => .addr64,
                else => .addr64,
            };
            try obj.relocations.append(gpa, .{
                .section_idx = @as(u16, @intCast(target_sec_idx)),
                .offset = r_offset,
                .symbol = sym_name,
                .kind = kind,
                .addend = r_addend,
            });
        }
    }

    return obj;
}

/// Read a NUL-terminated string from `strtab` at `off`.
fn cstr(strtab: []const u8, off: usize) []const u8 {
    if (off >= strtab.len) return "";
    const end = std.mem.indexOf(u8, strtab[off..], &[_]u8{0}) orelse strtab.len - off;
    return strtab[off..off + end];
}

/// PE/COFF object reader.
fn readCoffObject(gpa: Allocator, path: []const u8, file_bytes: []u8) !Object {
    if (file_bytes.len < 20) return error.ObjectReadFailed;

    const num_sections = @as(u64, @intCast(readU16(file_bytes, 2)));
    const ptr_to_symtab = readU32(file_bytes, 8);
    const num_symbols = readU32(file_bytes, 12);

    if (num_sections == 0) return error.ObjectReadFailed;
    if (20 + num_sections * 40 > @as(u64, file_bytes.len)) return error.ObjectReadFailed;

    var obj = Object{
        .path = path,
        .format = .pe_coff,
        .file_bytes = file_bytes,
        .sections = .empty,
        .symbols = .empty,
        .relocations = .empty,
    };
    errdefer obj.deinit(gpa);

    // Section table: 40 bytes each, starting at offset 20.
    var empty: [0]u8 = undefined;
    for (0..num_sections) |si| {
        const off = 20 + @as(u64, si) * 40;
        const sec_data = file_bytes[@intCast(off)..@intCast(off + 40)];
        const raw_size = readU32(sec_data, 16);
        const raw_ptr = readU32(sec_data, 20);
        const num_relocs = @as(u64, @intCast(readU16(sec_data, 32)));
        const characteristics = readU32(sec_data, 36);
        const content = if (raw_size == 0) empty[0..] else file_bytes[@intCast(raw_ptr)..@intCast(raw_ptr + raw_size)];
        try obj.sections.append(gpa, .{
            .name = coffShortName(sec_data, 0),
            .offset = raw_ptr,
            .size = raw_size,
            .flags = characteristics,
            .type_ = characteristics,
            .content = content,
        });
        _ = num_relocs;
    }

    // String table follows the symbol table.
    var strtab: []const u8 = empty[0..];
    var sym_data: []const u8 = empty[0..];
    if (ptr_to_symtab != 0 and num_symbols != 0) {
        const strtab_start = @as(u64, ptr_to_symtab) + num_symbols * CoffSymSize;
        if (strtab_start + 4 <= @as(u64, file_bytes.len)) {
            // First 4 bytes of the string table are its total size.
            strtab = file_bytes[@intCast(strtab_start + 4)..];
        }
        sym_data = file_bytes[@intCast(ptr_to_symtab)..@intCast(ptr_to_symtab + num_symbols * CoffSymSize)];
        var si: u32 = 0;
        while (si < num_symbols) : (si += 1) {
            const soff = @as(u64, si) * CoffSymSize;
            const name_field = sym_data[@intCast(soff)..@intCast(soff + 8)];
            const value = readU32(sym_data, @intCast(soff + 8));
            const section_number = @as(u16, readU16(sym_data, @intCast(soff + 12)));
            const storage_class = sym_data[@intCast(soff + 16)];
            const aux_count = sym_data[@intCast(soff + 17)];

            const sec_name = if (section_number == CoffSectionUndefined) null else secNameByIndex(obj.sections, section_number);
            try obj.symbols.append(gpa, .{
                .name = coffSymName(name_field, strtab),
                .section = sec_name,
                .value = value,
                .size = 0,
                .binding = if (storage_class == 2) .global else .local, // IMAGE_SYM_CLASS_EXTERNAL
            });

            si += @as(u32, aux_count);
        }
    }

    // Relocations: walk each section's relocation table.
    for (0..num_sections) |si| {
        const off = 20 + @as(u64, si) * 40;
        const sec_data = file_bytes[@intCast(off)..@intCast(off + 40)];
        const reloc_ptr = readU32(sec_data, 24);
        const num_relocs = @as(u64, @intCast(readU16(sec_data, 32)));
        if (num_relocs == 0) continue;
        if (reloc_ptr + num_relocs * CoffRelocSize > @as(u64, file_bytes.len)) return error.ObjectReadFailed;
        const reloc_data = file_bytes[@intCast(reloc_ptr)..@intCast(reloc_ptr + num_relocs * CoffRelocSize)];
        var ri: u64 = 0;
        while (ri < num_relocs) : (ri += 1) {
            const roff = ri * CoffRelocSize;
            const r_offset = readU32(reloc_data, @intCast(roff + 0));
            const sym_index = readU32(reloc_data, @intCast(roff + 4));
            const r_type = readU16(reloc_data, @intCast(roff + 8));
            var sym_name: []const u8 = "";
            if (sym_index < num_symbols) sym_name = coffSymNameAt(sym_data, strtab, sym_index);
            const kind: RelocKind = switch (r_type) {
                CoffRelocRel32 => .pc32,
                CoffRelocAddr64 => .addr64,
                else => .addr64,
            };
            try obj.relocations.append(gpa, .{
                .section_idx = @truncate(si + 1), // COFF sections are 1-based
                .offset = r_offset,
                .symbol = sym_name,
                .kind = kind,
                .addend = 0, // PE/COFF addend is implicit at the site
            });
        }
    }

    return obj;
}

/// Read a short (inline) COFF symbol/section name from an 8-byte field.
fn coffShortName(field: []const u8, off: usize) []const u8 {
    const nul = std.mem.indexOf(u8, field[off..off + 8], &[_]u8{0}) orelse 8;
    return field[off..off + nul];
}

/// Look up a section name by its 1-based COFF section number.
fn secNameByIndex(sections: std.ArrayList(Section), number: u16) ?[]const u8 {
    const sec_count: u16 = @intCast(sections.items.len);
    if (number == 0 or number > sec_count) return null;
    return sections.items[@as(usize, number) - 1].name;
}

/// Read a COFF symbol name, handling the string table for long names.
fn coffSymName(field: []const u8, strtab: []const u8) []const u8 {
    const nul = std.mem.indexOf(u8, field, &[_]u8{0});
    if (nul) |n| return field[0..n];
    // Long name: the writer stores the offset (high bit set on byte 0) in
    // bytes 0..3; bytes 4..7 are zero.
    if (field[0] & 0x80 != 0) {
        const offset = @as(u64, (readU32(field, 0) & 0x7FFF_FFFF));
        return strtabName(strtab, offset);
    }
    return field[0..0];
}

/// Read a COFF symbol name by symbol-table index (for relocations).
fn coffSymNameAt(sym_data: []const u8, strtab: []const u8, index: u32) []const u8 {
    const soff = @as(usize, index) * 18;
    if (soff + 8 > sym_data.len) return "";
    return coffSymName(sym_data[soff..soff + 8], strtab);
}

/// Read a NUL-terminated name from the string table at `offset` (offset into
/// the name area, i.e. past the 4-byte size dword).
fn strtabName(strtab: []const u8, offset: u64) []const u8 {
    if (offset >= @as(u64, strtab.len)) return "";
    const end = std.mem.indexOf(u8, strtab[offset..], &[_]u8{0}) orelse strtab.len - offset;
    return strtab[offset..offset + end];
}

/// Resolve every undefined symbol in `program` against `runtime`.
///
/// Collects all defined symbols from both objects, then walks `program`'s
/// undefined symbols (those with `section == null`). For each one, looks it
/// up in `runtime`'s defined symbols. Symbols still unresolved are recorded
/// in `ResolvedSymbols.undefined`; if any remain, returns `LinkError.UndefinedSymbol`.
///
/// `entry_symbol` is reserved for entry-point wiring (implemented later); it
/// is always defined in the program object and is not consulted here.
pub fn resolveSymbols(
    program: *Object,
    runtime: *Object,
    _: []const u8,
    gpa: Allocator,
) LinkError !ResolvedSymbols {
    // Map of runtime-defined symbols: name → (section, value).
    var runtime_defined: std.StringHashMap(ResolvedSymbol) =
        std.StringHashMap(ResolvedSymbol).init(gpa);
    defer runtime_defined.deinit();

    for (runtime.symbols.items) |sym| {
        if (sym.section != null) {
            // First definition wins; Tungsten does not emit duplicate symbols.
            if (runtime_defined.get(sym.name) == null) {
                runtime_defined.put(sym.name, .{
                    .section = sym.section.?,
                    .value = sym.value,
                }) catch |err| switch (err) {
                    else => return LinkError.WriteFailed,
                };
            }
        }
    }

    var result = ResolvedSymbols{
        .undefined = .empty,
        .resolved = std.StringHashMap(ResolvedSymbol).init(gpa),
    };
    errdefer result.deinit(gpa);

    for (program.symbols.items) |sym| {
        // Skip the ELF STN_UNDEF null symbol (index 0, empty name).
        if (sym.name.len == 0) continue;
        if (sym.section == null) {
            if (runtime_defined.get(sym.name)) |addr| {
                result.resolved.put(sym.name, addr) catch |err| switch (err) {
                    else => return LinkError.WriteFailed,
                };
            } else {
                result.undefined.append(gpa, sym.name) catch |err| switch (err) {
                    else => return LinkError.WriteFailed,
                };
            }
        }
    }

    if (result.undefined.items.len > 0) {
        const name = result.undefined.items[0];
        std.debug.print("Ferro: undefined symbol '{s}' not found in program or runtime archive\n", .{name});
        return error.UndefinedSymbol;
    }

    return result;
}

/// Find a section by name in `obj`, or null if absent.
fn findSectionByName(obj: *Object, name: []const u8) ?*Section {
    for (obj.sections.items) |*sec| {
        if (std.mem.eql(u8, sec.name, name)) return sec;
    }
    return null;
}

/// Size of a named section in `obj`, or 0 if absent.
fn sectionSize(obj: *Object, name: []const u8) u64 {
    const sec = findSectionByName(obj, name) orelse return 0;
    return sec.size;
}

/// Apply a single relocation to `buf` (merged .text or .data).
///
/// `section_base` is the merged-image address where `buf` starts.
/// `symbols` maps symbol names to their merged addresses.
fn applyReloc(
    rel: *const Relocation,
    section_base: u64,
    buf: []u8,
    symbols: *std.StringHashMap(ResolvedSymbol),
) !void {
    const sym_addr = symbols.get(rel.symbol) orelse return error.RelocationFailed;
    const s = sym_addr.value;
    const p = section_base + rel.offset;
    const off = @as(usize, rel.offset);

    switch (rel.kind) {
        .pc32 => {
            // S + A - P, sign-extended to 64, must fit in i32.
            const s_i64: i64 = @intCast(s);
            const p_i64: i64 = @intCast(p);
            const disp: i64 = s_i64 + rel.addend - p_i64;
            if (disp < @as(i64, std.math.minInt(i32)) or disp > @as(i64, std.math.maxInt(i32))) {
                return error.RelocationFailed;
            }
            if (off + 4 > buf.len) return error.RelocationFailed;
            const disp_i32: i32 = @intCast(disp);
            const bytes = std.mem.asBytes(&disp_i32);
            for (bytes, 0..4) |b, i| {
                buf[off + i] = b;
            }
        },
        .addr64 => {
            // S + A.
            const addend_u64: u64 = @intCast(rel.addend);
            const abs: u64 = s + addend_u64;
            if (off + 8 > buf.len) return error.RelocationFailed;
            const bytes = std.mem.asBytes(&abs);
            for (bytes, 0..8) |b, i| {
                buf[off + i] = b;
            }
        },
    }
}

/// Apply relocations and merge `.text`/`.data`/`.bss` from program object
/// and runtime into output sections.
///
/// Merged layout (relative addresses starting at 0):
///   .text: [0, merged_text_size)        — program .text, then runtime .text
///   .data: [merged_text_size, ...)      — program .data, then runtime .data
///   .bss:  zero-initialized, size = sum of both .bss sizes
///
/// Returns `RelocationFailed` if a referenced symbol is undefined or a PC32
/// displacement is out of range.
pub fn applyRelocations(
    program: *Object,
    runtime: *Object,
    resolved: *ResolvedSymbols,
    gpa: Allocator,
) !MergedImage {
    // ---- Locate sections ----
    const prog_text = findSectionByName(program, ".text") orelse return error.ObjectReadFailed;
    const prog_data = findSectionByName(program, ".data") orelse return error.ObjectReadFailed;
    const rt_text = findSectionByName(runtime, ".text") orelse return error.ObjectReadFailed;
    const rt_data = findSectionByName(runtime, ".data") orelse return error.ObjectReadFailed;

    const prog_text_size = prog_text.size;
    const prog_data_size = prog_data.size;
    const rt_text_size = rt_text.size;
    const rt_data_size = rt_data.size;
    const prog_bss_size = sectionSize(program, ".bss");
    const rt_bss_size = sectionSize(runtime, ".bss");

    // Merged layout (relative addresses starting at 0).
    const merged_text_size = prog_text_size + rt_text_size;
    const data_base = merged_text_size; // .data starts right after .text
    const merged_data_size = prog_data_size + rt_data_size;
    const merged_bss_size = prog_bss_size + rt_bss_size;

    // ---- Build merged .text ----
    var merged_text = try gpa.alloc(u8, merged_text_size);
    if (prog_text_size > 0) {
        var i: usize = 0;
        while (i < @as(usize, prog_text_size)) : (i += 1) {
            merged_text[i] = prog_text.content[i];
        }
    }
    if (rt_text_size > 0) {
        var i: usize = 0;
        while (i < @as(usize, rt_text_size)) : (i += 1) {
            merged_text[@as(usize, prog_text_size) + i] = rt_text.content[i];
        }
    }

    // ---- Build merged .data ----
    var merged_data = try gpa.alloc(u8, merged_data_size);
    if (prog_data_size > 0) {
        var i: usize = 0;
        while (i < @as(usize, prog_data_size)) : (i += 1) {
            merged_data[i] = prog_data.content[i];
        }
    }
    if (rt_data_size > 0) {
        var i: usize = 0;
        while (i < @as(usize, rt_data_size)) : (i += 1) {
            merged_data[@as(usize, prog_data_size) + i] = rt_data.content[i];
        }
    }

    // ---- Build symbol address map ----
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);

    // Program-defined symbols (.text / .data only).
    for (program.symbols.items) |sym| {
        if (sym.section == null) continue;
        const sec = sym.section.?;
        var addr: u64 = 0;
        if (std.mem.eql(u8, sec, ".text")) {
            addr = sym.value;
        } else if (std.mem.eql(u8, sec, ".data")) {
            addr = data_base + sym.value;
        } else {
            continue;
        }
        if (symbols.get(sym.name) == null) {
            try symbols.put(sym.name, .{ .section = sec, .value = addr });
        }
    }

    // Runtime-defined symbols (.text / .data only). First definition wins.
    for (runtime.symbols.items) |sym| {
        if (sym.section == null) continue;
        const sec = sym.section.?;
        var addr: u64 = 0;
        if (std.mem.eql(u8, sec, ".text")) {
            addr = prog_text_size + sym.value;
        } else if (std.mem.eql(u8, sec, ".data")) {
            addr = data_base + prog_data_size + sym.value;
        } else {
            continue;
        }
        if (symbols.get(sym.name) == null) {
            try symbols.put(sym.name, .{ .section = sec, .value = addr });
        }
    }

    // Resolved undefined program symbols -> point to runtime definitions,
    // adjusted to merged addresses.
    var iter = resolved.resolved.iterator();
    while (iter.next()) |node| {
        const name = node.key_ptr.*;
        const rt_addr = node.value_ptr.*;
        var addr: u64 = 0;
        if (std.mem.eql(u8, rt_addr.section, ".text")) {
            addr = prog_text_size + rt_addr.value;
        } else if (std.mem.eql(u8, rt_addr.section, ".data")) {
            addr = data_base + prog_data_size + rt_addr.value;
        } else {
            continue;
        }
        try symbols.put(name, .{ .section = rt_addr.section, .value = addr });
    }

    // ---- Apply relocations: program object ----
    for (program.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text else merged_data;
        const base = if (rel.section_idx == 1) @as(u64, 0) else data_base;
        try applyReloc(&rel, base, buf, &symbols);
    }

    // ---- Apply relocations: runtime object ----
    for (runtime.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text else merged_data;
        const base = if (rel.section_idx == 1) prog_text_size else data_base + prog_data_size;
        try applyReloc(&rel, base, buf, &symbols);
    }

    return MergedImage{
        .text = merged_text,
        .data = merged_data,
        .bss_size = merged_bss_size,
        .symbols = symbols,
    };
}

// ============================================================================
// ELF64 executable writer (Linux)
// ============================================================================

const ElfIdent = packed struct {
    magic0: u8 = 0x7f,
    magic1: u8 = 'E',
    magic2: u8 = 'L',
    magic3: u8 = 'F',
    class: u8 = 2,
    data: u8 = 1,
    version: u8 = 1,
    os_abi: u8 = 0,
    abi_version: u8 = 0,
    pad0: u8 = 0,
    pad1: u8 = 0,
    pad2: u8 = 0,
    pad3: u8 = 0,
    pad4: u8 = 0,
    pad5: u8 = 0,
    pad6: u8 = 0,
};

const Elf64EhdrExec = packed struct {
    e_ident: ElfIdent,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};
comptime {
    _ = @sizeOf(Elf64EhdrExec) == 64;
}

const Elf64Phdr = packed struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};
comptime {
    _ = @sizeOf(Elf64Phdr) == 56;
}

const EtExec: u16 = 2;
const PtLoad: u32 = 1;
const PfR: u32 = 0x1;
const PfW: u32 = 0x2;
const PfX: u32 = 0x4;

/// The Linux user-space entry point is `_start`, which Ferro synthesizes to
/// call `_main` (the symbol Tungsten names as program entry). `_start` runs:
///
///     call _main          ; rel32 relocation against _main's merged address
///     mov edi, eax        ; exit code = _main's return value
///     mov eax, 60         ; sys_exit
///     syscall
///
/// The `call _main` displacement is computed at write time against the stub's
/// own address, so no external shim assembly is needed.
fn buildLinuxStartStub(gpa: Allocator, main_addr: u64, stub_addr: u64) ![]u8 {
    // call _main (E8 disp32) + mov edi,eax + mov eax,60 + syscall = 14 bytes.
    var stub = try gpa.alloc(u8, 14);
    stub[0] = 0xe8; // E8 = call rel32
    const disp: i64 = @as(i64, @bitCast(main_addr)) - @as(i64, @bitCast(stub_addr)) - 5;
    const disp_bytes = std.mem.asBytes(&disp);
    for (0..4) |i| stub[1 + i] = disp_bytes[i];
    stub[5] = 0x89; // mov edi, eax
    stub[6] = 0xc7;
    stub[7] = 0xb8; // mov eax, 60
    stub[8] = 0x3c;
    stub[9] = 0x00;
    stub[10] = 0x00;
    stub[11] = 0x00;
    stub[12] = 0x0f; // syscall
    stub[13] = 0x05;
    return stub;
}

/// Write an ELF executable (ET_EXEC) whose entry `_start` calls `_main`.
///
/// Layout: ELF header (64) + 2x PT_LOAD program headers (.text R/X, .data R/W)
/// + .text content (with `_start` appended) + .data content.
///
/// `entry_symbol_addr` is the merged-image address of `_main` (from
/// `MergedImage.symbols`); `_start` is placed at the end of merged `.text`.
fn writeExecutableElf(
    image: *MergedImage,
    entry_symbol_addr: u64,
    gpa: Allocator,
) ![]u8 {
    const text = image.text;
    const data = image.data;
    const text_size = @as(u64, @intCast(text.len));
    const data_size = @as(u64, @intCast(data.len));

    // `_start` lives at the end of merged `.text` (relative offset `start_offset`);
    // `_main` address comes from symbol resolution. Both are relative to image base
    // 0, so the `call _main` displacement is `main_addr - start_offset - 5`; the
    // vaddr base (0x400000) cancels at runtime.
    const text_vaddr: u64 = 0x400000;
    const start_offset = text_size;
    const stub = try buildLinuxStartStub(gpa, entry_symbol_addr, start_offset);
    defer gpa.free(stub);

    const full_text_size = text_size + stub.len;
    var full_text = try gpa.alloc(u8, full_text_size);
    defer gpa.free(full_text);
    for (text, 0..text.len) |b, i| full_text[i] = b;
    for (stub, 0..stub.len) |b, i| full_text[text_size + i] = b;

    const data_vaddr = text_vaddr + full_text_size;

    const ehdr_size: u64 = 64;
    const phdr_count: u64 = 2;
    const phdr_size: u64 = 56 * phdr_count;
    const text_file_off = ehdr_size + phdr_size;
    const data_file_off = text_file_off + full_text_size;
    const total_size = data_file_off + data_size;

    var buf = try gpa.alloc(u8, total_size);
    var pos: u64 = 0;

    // ---- ELF header ----
    const ehdr = Elf64EhdrExec{
        .e_ident = .{},
        .e_type = EtExec,
        .e_machine = 62, // EM_X86_64
        .e_version = 1,
        .e_entry = text_vaddr + start_offset,
        .e_phoff = ehdr_size,
        .e_shoff = total_size, // section headers appended at end (optional)
        .e_flags = 0,
        .e_ehsize = 64,
        .e_phentsize = 56,
        .e_phnum = @intCast(phdr_count),
        .e_shentsize = 64,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const ehdr_bytes = std.mem.asBytes(&ehdr);
    for (0..ehdr_bytes.len) |i| {
        buf[pos + @as(u64, i)] = ehdr_bytes[i];
    }
    pos += ehdr_size;

    // ---- Program headers ----
    // PT_LOAD .text: R+X
    {
        const ph = Elf64Phdr{
            .p_type = PtLoad,
            .p_flags = PfR | PfX,
            .p_offset = text_file_off,
            .p_vaddr = text_vaddr,
            .p_paddr = text_vaddr,
            .p_filesz = full_text_size,
            .p_memsz = full_text_size,
            .p_align = 0x1000,
        };
        const ph_bytes = std.mem.asBytes(&ph);
        for (0..ph_bytes.len) |i| {
            buf[pos + @as(u64, i)] = ph_bytes[i];
        }
        pos += 56;
    }
    // PT_LOAD .data: R+W (includes .bss in memsz)
    {
        const ph = Elf64Phdr{
            .p_type = PtLoad,
            .p_flags = PfR | PfW,
            .p_offset = data_file_off,
            .p_vaddr = data_vaddr,
            .p_paddr = data_vaddr,
            .p_filesz = data_size,
            .p_memsz = data_size + image.bss_size,
            .p_align = 0x1000,
        };
        const ph_bytes = std.mem.asBytes(&ph);
        for (0..ph_bytes.len) |i| {
            buf[pos + @as(u64, i)] = ph_bytes[i];
        }
        pos += 56;
    }

    // ---- .text content ----
    for (full_text, 0..full_text.len) |b, i| {
        buf[text_file_off + @as(u64, i)] = b;
    }
    // ---- .data content ----
    for (data, 0..data.len) |b, i| {
        buf[data_file_off + @as(u64, i)] = b;
    }

    return buf;
}

/// Write the buffer to `exe_path` (no extension on Linux).
fn writeExecutableElfToFile(
    io: std.Io,
    exe_path: []const u8,
    buf: []u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = buf });
}

// ============================================================================
// PE/COFF executable writer (Windows)
// ============================================================================

const PeMagic: u16 = 0x20b; // PE32+
const PeSubsystemConsole: u16 = 3;
const PeSubsystemGui: u16 = 2;
const PeCharacteristicsExecImage: u16 = 0x0002;
const PeCharacteristicsRelocsStripped: u16 = 0x0001;
const PeSectionCount: u16 = 3; // .text, .data, .bss
const PeSectionText: u16 = 0;
const PeSectionData: u16 = 1;
const PeSectionBss: u16 = 2;

const PeFileAlign: u64 = 0x200;
const PeSecAlign: u64 = 0x1000;
const PeImageBase: u64 = 0x140000000;

const PeSizeOfOptionalHeader: u16 = 240;
const PeNumberOfRvaAndSizes: u32 = 16;
const PeDataDirEntrySize: u64 = 8;

fn alignUp(v: u64, aln: u64) u64 {
    return (v + aln - 1) / aln * aln;
}

/// The Windows entry point `main` that Ferro synthesizes to call `_main`:
///
///     call _main      ; rel32 relocation against _main's merged address
///     ret             ; return (clean exit handled by imports/runtime later)
///
/// `call _main`'s displacement is computed against the stub's own address, so
/// no external shim assembly is needed. The image base cancels because both
/// `_main` and the stub are relative to the same image base.
fn buildWindowsMainStub(gpa: Allocator, main_rel_addr: u64, stub_rel_addr: u64) ![]u8 {
    var stub = try gpa.alloc(u8, 6); // E8 disp32 + C3 ret
    stub[0] = 0xe8; // E8 = call rel32
    const disp: i64 = @as(i64, @bitCast(main_rel_addr)) - @as(i64, @bitCast(stub_rel_addr)) - 5;
    const disp_bytes = std.mem.asBytes(&disp);
    for (0..4) |i| stub[1 + i] = disp_bytes[i];
    stub[5] = 0xc3; // ret
    return stub;
}

fn putU16At(buf: []u8, pos: u64, v: u16) void {
    buf[pos] = @truncate(v);
    buf[pos + 1] = @truncate(v >> 8);
}

fn putU32At(buf: []u8, pos: u64, v: u32) void {
    buf[pos] = @truncate(v);
    buf[pos + 1] = @truncate(v >> 8);
    buf[pos + 2] = @truncate(v >> 16);
    buf[pos + 3] = @truncate(v >> 24);
}

fn putU64At(buf: []u8, pos: u64, v: u64) void {
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        buf[pos + @as(u64, i)] = @truncate(v >> (i * 8));
    }
}

fn writeExecutablePe(
    image: *MergedImage,
    entry_symbol_addr: u64,
    subsystem: Subsystem,
    gpa: Allocator,
) ![]u8 {
    const text = image.text;
    const data = image.data;
    const text_size = @as(u64, @intCast(text.len));
    const data_size = @as(u64, @intCast(data.len));

    const text_sec_vaddr: u64 = PeSecAlign;
    const stub_rel_addr = text_sec_vaddr + text_size;
    const stub = try buildWindowsMainStub(gpa, entry_symbol_addr, stub_rel_addr);
    defer gpa.free(stub);

    const full_text_size = text_size + stub.len;

    const headers_raw_size: u64 = 64 + 4 + 20 + @as(u64, PeSizeOfOptionalHeader) + @as(u64, PeSectionCount) * 40;
    const size_of_headers = alignUp(headers_raw_size, PeFileAlign);

    const text_file_off = size_of_headers;
    const data_file_off = alignUp(text_file_off + full_text_size, PeFileAlign);
    const total_file_size = alignUp(data_file_off + data_size, PeFileAlign);

    const text_sec_vaddr_final = text_sec_vaddr;
    const data_sec_vaddr = alignUp(text_sec_vaddr_final + full_text_size, PeSecAlign);
    const bss_sec_vaddr = alignUp(data_sec_vaddr + data_size, PeSecAlign);
    const size_of_image = alignUp(bss_sec_vaddr + image.bss_size, PeSecAlign);

    const subsystem_val = if (subsystem == .gui) PeSubsystemGui else PeSubsystemConsole;
    const address_of_entry_point = PeImageBase + stub_rel_addr;

    var buf = try gpa.alloc(u8, total_file_size);
    for (buf) |*b| b.* = 0;
    var pos: u64 = 0;

    buf[0] = 'M'; buf[1] = 'Z';
    putU32At(buf, 60, 64); // e_lfanew = offset to PE signature
    pos = 64;

    // ---- PE signature "PE\0\0" ----
    buf[pos] = 'P'; buf[pos + 1] = 'E'; buf[pos + 2] = 0; buf[pos + 3] = 0;
    pos += 4;

    // ---- COFF file header (20 bytes) ----
    putU16At(buf, pos, 0x8664); pos += 2; // machine
    putU16At(buf, pos, PeSectionCount); pos += 2;
    putU32At(buf, pos, 0); pos += 4; // time_date_stamp
    putU32At(buf, pos, 0); pos += 4; // pointer_to_symbol_table
    putU32At(buf, pos, 0); pos += 4; // number_of_symbols
    putU16At(buf, pos, PeSizeOfOptionalHeader); pos += 2;
    putU16At(buf, pos, PeCharacteristicsExecImage | PeCharacteristicsRelocsStripped); pos += 2;

    // ---- Optional header (PE32+, 240 bytes) ----
    putU16At(buf, pos, PeMagic); pos += 2; // magic
    pos += 2; // linker version (major/minor = 0)
    putU32At(buf, pos, @as(u32, @intCast(full_text_size))); pos += 4; // size_of_code
    putU32At(buf, pos, @as(u32, @intCast(data_size))); pos += 4; // size_of_initialized_data
    putU32At(buf, pos, @intCast(image.bss_size)); pos += 4; // size_of_uninitialized_data
    putU32At(buf, pos, @as(u32, @intCast(address_of_entry_point & 0xFFFF_FFFF))); pos += 4; // address_of_entry_point (low 32)
    putU32At(buf, pos, @as(u32, @intCast(text_sec_vaddr_final))); pos += 4; // base_of_code
    putU64At(buf, pos, PeImageBase); pos += 8; // image_base
    putU32At(buf, pos, PeSecAlign); pos += 4; // section_alignment
    putU32At(buf, pos, PeFileAlign); pos += 4; // file_alignment
    pos += 6; // os version (major/minor) + image version (major/minor) = 0
    pos += 4; // win32_version_value = 0
    putU32At(buf, pos, @as(u32, @intCast(size_of_image))); pos += 4; // size_of_image
    putU32At(buf, pos, @as(u32, @intCast(size_of_headers))); pos += 4; // size_of_headers
    putU32At(buf, pos, 0); pos += 4; // checksum
    putU16At(buf, pos, subsystem_val); pos += 2; // subsystem
    putU16At(buf, pos, 0); pos += 2; // dll_characteristics
    putU64At(buf, pos, 0x100000); pos += 8; // size_of_stack_reserve
    putU64At(buf, pos, 0x1000); pos += 8; // size_of_stack_commit
    putU64At(buf, pos, 0x100000); pos += 8; // size_of_heap_reserve
    putU64At(buf, pos, 0x1000); pos += 8; // size_of_heap_commit
    putU32At(buf, pos, 0); pos += 4; // loader_flags
    putU32At(buf, pos, PeNumberOfRvaAndSizes); pos += 4; // number_of_rva_and_sizes
    // data directories: 16 x 8 bytes = 128 bytes, all zero (already zeroed)
    pos += PeNumberOfRvaAndSizes * PeDataDirEntrySize;

    // ---- Section table (3 x 40 bytes) ----
    const sec_names = [_][]const u8{ ".text", ".data", ".bss" };
    const sec_characteristics = [_]u32{
        0x60000020, // .text: CNT_CODE | MEM_EXECUTE | MEM_READ
        0x60000040, // .data: CNT_INITIALIZED_DATA | MEM_READ | MEM_WRITE
        0x80000080, // .bss: CNT_UNINITIALIZED_DATA | MEM_READ | MEM_WRITE
    };
    const sec_vaddrs = [_]u64{ text_sec_vaddr_final, data_sec_vaddr, bss_sec_vaddr };
    const sec_vsizes = [_]u64{ full_text_size, data_size, image.bss_size };
    const sec_file_offs = [_]u64{ text_file_off, data_file_off, 0 };
    const sec_raw_sizes = [_]u64{ full_text_size, data_size, 0 };

    var si: usize = 0;
    while (si < @as(usize, @intCast(PeSectionCount))) : (si += 1) {
        const soff = pos + @as(u64, si) * 40;
        for (0..8) |k| {
            buf[soff + @as(u64, k)] = if (k < sec_names[si].len) sec_names[si][k] else 0;
        }
        putU32At(buf, soff + 8, @as(u32, @intCast(sec_vsizes[si])));       // virtual_size
        putU32At(buf, soff + 12, @as(u32, @intCast(sec_vaddrs[si])));      // virtual_address
        putU32At(buf, soff + 16, @as(u32, @intCast(sec_raw_sizes[si])));   // size_of_raw_data
        putU32At(buf, soff + 20, if (sec_raw_sizes[si] == 0) 0 else @as(u32, @intCast(sec_file_offs[si]))); // pointer_to_raw_data
        putU32At(buf, soff + 24, 0); // pointer_to_relocations (unused)
        putU32At(buf, soff + 28, 0); // pointer_to_line_numbers
        putU16At(buf, soff + 32, 0); // number_of_relocations
        putU16At(buf, soff + 34, 0); // number_of_line_numbers
        putU32At(buf, soff + 36, sec_characteristics[si]); // characteristics
    }
    pos = headers_raw_size; // section table ends at headers_raw_size

    // ---- .text raw data (program .text + main stub) ----
    for (text, 0..text.len) |b, i| {
        buf[text_file_off + @as(u64, i)] = b;
    }
    for (stub, 0..stub.len) |b, i| {
        buf[text_file_off + text_size + @as(u64, i)] = b;
    }
    // ---- .data raw data ----
    for (data, 0..data.len) |b, i| {
        buf[data_file_off + @as(u64, i)] = b;
    }

    return buf;
}

// ============================================================================
// Executable writer dispatch
// ============================================================================

/// Synthesize the platform entry point and write the final executable.
///
/// Linux: entry `_start` (at end of merged `.text`) calls `_main`.
/// Windows: entry `main` (at end of merged `.text`) calls `_main` per subsystem.
pub fn writeExecutable(
    image: *MergedImage,
    exe_path: []const u8,
    options: LinkOptions,
    gpa: Allocator,
    io: std.Io,
) !void {
    const main_addr = image.symbols.get(options.entry_symbol) orelse return error.UndefinedSymbol;

    switch (options.target) {
        .linux_x86_64 => {
            const buf = try writeExecutableElf(image, main_addr.value, gpa);
            defer gpa.free(buf);
            try writeExecutableElfToFile(io, exe_path, buf);
        },
        .windows_x86_64 => {
            const buf = try writeExecutablePe(image, main_addr.value, options.subsystem, gpa);
            defer gpa.free(buf);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = buf });
        },
    }
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

    var image = try applyRelocations(&object, &runtime, &resolved, gpa);
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

test "parseTarget accepts linux and windows (case-insensitive)" {
    try std.testing.expectEqual(.linux_x86_64, try parseTarget("linux"));
    try std.testing.expectEqual(.linux_x86_64, try parseTarget("Linux"));
    try std.testing.expectEqual(.linux_x86_64, try parseTarget("LINUX"));
    try std.testing.expectEqual(.windows_x86_64, try parseTarget("windows"));
    try std.testing.expectEqual(.windows_x86_64, try parseTarget("Windows"));
    if (parseTarget("osx")) |_| try std.testing.expect(false) else |err| {
        try std.testing.expectEqual(LinkDescriptionError.InvalidTarget, err);
    }
}

test "parseSubsystem accepts console and gui (case-insensitive)" {
    try std.testing.expectEqual(.console, try parseSubsystem("console"));
    try std.testing.expectEqual(.console, try parseSubsystem("Console"));
    try std.testing.expectEqual(.gui, try parseSubsystem("gui"));
    try std.testing.expectEqual(.gui, try parseSubsystem("GUI"));
    if (parseSubsystem("kernel")) |_| try std.testing.expect(false) else |err| {
        try std.testing.expectEqual(LinkDescriptionError.InvalidSubsystem, err);
    }
}

test "linkOptionsFromDescription maps a link description to LinkOptions" {
    const desc = LinkDescription{
        .target = "windows",
        .output = "hello.exe",
        .entry = "_main",
        .subsystem = "console",
        .runtime_lib = "wfr_std.lib",
        .input = "hello.o",
        .debug = false,
    };
    const opts = try linkOptionsFromDescription(desc);
    try std.testing.expectEqual(.windows_x86_64, opts.target);
    try std.testing.expectEqualStrings("_main", opts.entry_symbol);
    try std.testing.expectEqual(.console, opts.subsystem);
    try std.testing.expectEqual(false, opts.debug);
}

test "linkOptionsFromDescription rejects a bad target" {
    const desc = LinkDescription{
        .target = "osx",
        .output = "hello",
        .entry = "_main",
        .subsystem = "console",
        .runtime_lib = "wfr_std.lib",
        .input = "hello.o",
        .debug = false,
    };
    if (linkOptionsFromDescription(desc)) |_| try std.testing.expect(false) else |err| {
        try std.testing.expectEqual(LinkDescriptionError.InvalidTarget, err);
    }
}

test "readObject reads an ELF64 object Tungsten emitted (sections, symbols, relocations)" {
    const gpa = std.testing.allocator;
    const obj_elf = @import("obj_elf.zig");

    const text_bytes = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 }; // mov rax, rdi; ret
    const data_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0 };

    const symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "__g0", .section_idx = 2, .value = 0, .size = 6,
            .binding = .global, .is_func = false },
        obj_elf.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };

    const relocs = &.{
        obj_elf.Reloc{ .section_idx = 1, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 },
        obj_elf.Reloc{ .section_idx = 2, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 },
    };

    const input = obj_elf.ObjectInput{
        .text = &text_bytes,
        .data = &data_bytes,
        .bss_size = 0,
        .symbols = symbols,
        .relocs = relocs,
    };

    var w = obj_elf.Writer.init(gpa);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer gpa.free(bytes);

    const path = "ferro_read_elf_test.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    const io = std.testing.io;
    var object = try readObject(io, gpa, path);
    defer object.deinit(gpa);

    try std.testing.expectEqual(ObjectFormat.elf64, object.format);

    // Sections: NULL, .text, .data, .bss, .symtab, .strtab, .rela.text, .rela.data, .shstrtab
    try std.testing.expectEqual(9, object.sections.items.len);
    try std.testing.expectEqualSlices(u8, object.sections.items[1].content, &text_bytes);
    try std.testing.expectEqualSlices(u8, object.sections.items[2].content, &data_bytes);
    try std.testing.expectEqual(0, object.sections.items[3].content.len);

    // Symbols: STN_UNDEF (index 0) + _main + __g0 + puts.
    // `puts` is an undefined extern (SHN_UNDEF) so its section is null.
    try std.testing.expectEqual(4, object.symbols.items.len);
    // STN_UNDEF: null name, null section.
    try std.testing.expectEqualSlices(u8, object.symbols.items[0].name, &[_]u8{});
    try std.testing.expectEqual(null, object.symbols.items[0].section);
    try std.testing.expectEqualStrings("_main", object.symbols.items[1].name);
    try std.testing.expectEqualStrings(".text", object.symbols.items[1].section.?);
    try std.testing.expectEqualStrings("__g0", object.symbols.items[2].name);
    try std.testing.expectEqualStrings(".data", object.symbols.items[2].section.?);
    try std.testing.expectEqualStrings("puts", object.symbols.items[3].name);
    try std.testing.expectEqual(null, object.symbols.items[3].section);

    // Relocations: one PC32 in .text (puts), one ADDR64 in .data (__g0)
    try std.testing.expectEqual(2, object.relocations.items.len);
    try std.testing.expectEqualStrings("puts", object.relocations.items[0].symbol);
    try std.testing.expectEqual(.pc32, object.relocations.items[0].kind);
    try std.testing.expectEqual(-4, object.relocations.items[0].addend);
    try std.testing.expectEqualStrings("__g0", object.relocations.items[1].symbol);
    try std.testing.expectEqual(.addr64, object.relocations.items[1].kind);
    try std.testing.expectEqual(0, object.relocations.items[1].addend);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
}

test "readObject reads a PE/COFF object (sections, symbols, relocations)" {
    const gpa = std.testing.allocator;
    const obj_pe = @import("obj_pe.zig");

    const text_bytes = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 }; // mov rax, rdi; ret
    const data_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0 };

    // COFF section numbers are 1-based: .text=1, .data=2, .bss=3, 0=undefined.
    const symbols = &.{
        obj_pe.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_pe.Symbol{ .name = "__g0", .section_idx = 2, .value = 0, .size = 6,
            .binding = .global, .is_func = false },
        obj_pe.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };

    const relocs = &.{
        obj_pe.Reloc{ .section_idx = 1, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 },
        obj_pe.Reloc{ .section_idx = 2, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 },
    };

    const input = obj_pe.ObjectInput{
        .text = &text_bytes,
        .data = &data_bytes,
        .bss_size = 0,
        .symbols = symbols,
        .relocs = relocs,
    };

    var w = obj_pe.Writer.init(gpa);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer gpa.free(bytes);

    const path = "ferro_read_coff_test.obj";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    const io = std.testing.io;
    var object = try readObject(io, gpa, path);
    defer object.deinit(gpa);

    try std.testing.expectEqual(ObjectFormat.pe_coff, object.format);

    // Sections: .text, .data, .bss
    try std.testing.expectEqual(3, object.sections.items.len);
    try std.testing.expectEqualStrings(".text", object.sections.items[0].name);
    try std.testing.expectEqualSlices(u8, object.sections.items[0].content, &text_bytes);
    try std.testing.expectEqualStrings(".data", object.sections.items[1].name);
    try std.testing.expectEqualSlices(u8, object.sections.items[1].content, &data_bytes);
    try std.testing.expectEqualStrings(".bss", object.sections.items[2].name);
    try std.testing.expectEqual(0, object.sections.items[2].content.len);

    // Find the input symbols (section symbols come first in COFF).
    var main_idx: ?usize = null;
    var g0_idx: ?usize = null;
    var puts_idx: ?usize = null;
    var si: usize = 0;
    while (si < object.symbols.items.len) : (si += 1) {
        if (std.mem.eql(u8, object.symbols.items[si].name, "_main")) main_idx = si;
        if (std.mem.eql(u8, object.symbols.items[si].name, "__g0")) g0_idx = si;
        if (std.mem.eql(u8, object.symbols.items[si].name, "puts")) puts_idx = si;
    }
    try std.testing.expect(main_idx != null);
    try std.testing.expect(g0_idx != null);
    try std.testing.expect(puts_idx != null);

    try std.testing.expectEqualStrings("_main", object.symbols.items[main_idx.?].name);
    try std.testing.expectEqualStrings(".text", object.symbols.items[main_idx.?].section.?);
    try std.testing.expectEqualStrings("__g0", object.symbols.items[g0_idx.?].name);
    try std.testing.expectEqualStrings(".data", object.symbols.items[g0_idx.?].section.?);
    try std.testing.expectEqualStrings("puts", object.symbols.items[puts_idx.?].name);
    try std.testing.expectEqual(null, object.symbols.items[puts_idx.?].section);

    // Relocations: one PC32 in .text (puts), one ADDR64 in .data (__g0).
    // PE/COFF addends are implicit at the relocation site, so addend is 0 here.
    try std.testing.expectEqual(2, object.relocations.items.len);
    try std.testing.expectEqualStrings("puts", object.relocations.items[0].symbol);
    try std.testing.expectEqual(.pc32, object.relocations.items[0].kind);
    try std.testing.expectEqual(0, object.relocations.items[0].addend);
    try std.testing.expectEqualStrings("__g0", object.relocations.items[1].symbol);
    try std.testing.expectEqual(.addr64, object.relocations.items[1].kind);
    try std.testing.expectEqual(0, object.relocations.items[1].addend);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
}

test "readObject reports ObjectReadFailed for a non-ELF/non-COFF file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const path = "ferro_read_bad_test.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &[_]u8{ 0x00, 0x01, 0x02, 0x03 } });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    if (readObject(io, gpa, path)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.ObjectReadFailed, err);
    }
}

test "resolveSymbols resolves an undefined program symbol against the runtime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main defined in .text, puts undefined.
    const prog_text = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 };
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_resolve_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts defined in .text (section 1).
    const rt_text = [_]u8{ 0x90, 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 2,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_resolve_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    var program = try readObject(io, gpa, prog_path);
    defer program.deinit(gpa);
    var runtime = try readObject(io, gpa, rt_path);
    defer runtime.deinit(gpa);

    var resolved = try resolveSymbols(&program, &runtime, "_main", gpa);
    defer resolved.deinit(gpa);

    try std.testing.expectEqual(0, resolved.undefined.items.len);
    if (resolved.resolved.get("puts")) |addr| {
        try std.testing.expectEqualStrings(".text", addr.section);
        try std.testing.expectEqual(0, addr.value);
    } else {
        try std.testing.expect(false);
    }
}

test "resolveSymbols reports UndefinedSymbol when the runtime does not define it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main defined, nosuch_symbol undefined.
    const prog_text = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 };
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "nosuch_symbol", .section_idx = obj_elf.ShnUndef, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_resolve_missing_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: does not define nosuch_symbol.
    const rt_text = [_]u8{ 0x90, 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "other", .section_idx = 0, .value = 0, .size = 2,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_resolve_missing_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    var program = try readObject(io, gpa, prog_path);
    defer program.deinit(gpa);
    var runtime = try readObject(io, gpa, rt_path);
    defer runtime.deinit(gpa);

    if (resolveSymbols(&program, &runtime, "_main", gpa)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.UndefinedSymbol, err);
    }
}

test "applyRelocations merges sections and applies PC32 + ADDR64 relocations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main in .text calls `puts` (extern, PC32 reloc at offset 0)
    // and references string literal `__g0` (ADDR64 reloc at data offset 0).
    // `__g0` is defined in the program object; `puts` is undefined here and
    // resolved against the runtime archive.
    const prog_text = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 }; // mov rax, rdi; ret
    const prog_data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }; // 8-byte placeholder for __g0 address
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "__g0", .section_idx = 2, .value = 0, .size = 8,
            .binding = .global, .is_func = false },
        obj_elf.Symbol{ .name = "puts", .section_idx = obj_elf.ShnUndef, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_relocs = &.{
        obj_elf.Reloc{ .section_idx = 1, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 },
        obj_elf.Reloc{ .section_idx = 2, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = prog_relocs,
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_apply_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts defined at .text offset 0.
    const rt_text = [_]u8{ 0x90, 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 2,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_apply_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    var program = try readObject(io, gpa, prog_path);
    defer program.deinit(gpa);
    var runtime = try readObject(io, gpa, rt_path);
    defer runtime.deinit(gpa);

    var resolved = try resolveSymbols(&program, &runtime, "_main", gpa);
    defer resolved.deinit(gpa);

    var image = try applyRelocations(&program, &runtime, &resolved, gpa);
    defer image.deinit(gpa);

    // Merged layout: .text = prog(4) + rt(2) = 6 bytes; .data = prog(8) + rt(0) = 8 bytes.
    // data_base = 6.
    try std.testing.expectEqual(6, image.text.len);
    try std.testing.expectEqual(8, image.data.len);

    // puts is runtime .text offset 0 => merged address 4 (prog_text_size). call site is .text offset 0.
    // PC32: S(4) + A(-4) - P(0) = 0 => disp32 = 0.
    try std.testing.expectEqualSlices(u8, image.text[0..4], &[_]u8{ 0x00, 0x00, 0x00, 0x00 });

    // __g0 ADDR64: S(data_base(6) + 0) + A(0) = 6 at .data offset 0 (little-endian u64).
    try std.testing.expectEqualSlices(u8, image.data[0..8], &[_]u8{ 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });

    // __g0 symbol resolves to merged address 6 in .data.
    if (image.symbols.get("__g0")) |addr| {
        try std.testing.expectEqualStrings(".data", addr.section);
        try std.testing.expectEqual(6, addr.value);
    } else {
        try std.testing.expect(false);
    }
}

test "writeExecutableElf produces an ELF executable whose _start calls _main" {
    const gpa = std.testing.allocator;

    // Merged image: _main at relative address 42, 2 bytes of program .text.
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    try symbols.put("_main", .{ .section = ".text", .value = 42 });

    var prog_text = [_]u8{ 0x90, 0x90 };
    var prog_data = [_]u8{};
    var image = MergedImage{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = symbols,
    };

    const buf = try writeExecutableElf(&image, 42, gpa);
    defer gpa.free(buf);

    // ELF header: ET_EXEC executable, x86-64.
    try std.testing.expectEqualSlices(u8, buf[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(2, readU16(buf, 16));      // e_type = ET_EXEC
    try std.testing.expectEqual(62, readU16(buf, 18));     // e_machine = EM_X86_64
    // e_entry = vaddr of _start = 0x400000 + start_offset(2) = 0x400002.
    try std.testing.expectEqual(0x400002, readU64(buf, 24));

    // Two PT_LOAD program headers at offset 64.
    try std.testing.expectEqual(1, readU32(buf, 64 + 0));  // p_type = PT_LOAD (.text)
    try std.testing.expectEqual(1, readU32(buf, 64 + 56)); // p_type = PT_LOAD (.data)

    // .text content at file offset 64 + 2*56 = 176, followed by the _start stub.
    const text_file_off: u64 = 64 + 2 * 56;
    try std.testing.expectEqualSlices(u8, buf[text_file_off..text_file_off + 2], &[_]u8{ 0x90, 0x90 });

    const stub_off = text_file_off + 2;
    try std.testing.expectEqual(0xe8, buf[stub_off]); // E8 = call rel32
    // disp = main_addr(42) - start_offset(2) - 5 = 35 = 0x23 (little-endian).
    try std.testing.expectEqualSlices(u8, buf[stub_off + 1..stub_off + 5], &[_]u8{ 0x23, 0x00, 0x00, 0x00 });
    // mov edi,eax; mov eax,60; syscall
    try std.testing.expectEqualSlices(
        u8,
        buf[stub_off + 5..stub_off + 14],
        &[_]u8{ 0x89, 0xc7, 0xb8, 0x3c, 0x00, 0x00, 0x00, 0x0f, 0x05 },
    );
}

test "writeExecutable reports UndefinedSymbol when entry symbol is absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    var prog_text = [_]u8{ 0x90 };
    var prog_data = [_]u8{};
    var image = MergedImage{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = symbols,
    };
    const opts = defaultLinkOptions(.linux_x86_64);
    if (writeExecutable(&image, "no-such-entry.exe", opts, gpa, io)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.UndefinedSymbol, err);
    }
}

test "linkObject writes an ELF executable whose entry _start calls _main" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main (ret) in .text, puts undefined.
    var prog_text = [_]u8{ 0xc3 };
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "puts", .section_idx = obj_elf.ShnUndef, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_entry_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts (nop) defined in .text.
    const rt_text = [_]u8{ 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_entry_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    const exe_path = "ferro_entry.exe";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const opts = defaultLinkOptions(.linux_x86_64);
    try linkObject(io, gpa, prog_path, rt_path, exe_path, opts);

    const exe_bytes = try std.Io.Dir.cwd().readFileAlloc(io, exe_path, gpa, .unlimited);
    defer gpa.free(exe_bytes);

    try std.testing.expectEqualSlices(u8, exe_bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(2, readU16(exe_bytes, 16)); // ET_EXEC
    // e_entry = 0x400000 + start_offset. merged .text = prog(1) + rt(1) = 2, _start at offset 2.
    try std.testing.expectEqual(0x400002, readU64(exe_bytes, 24));

    const text_file_off: u64 = 64 + 2 * 56;
    const stub_off = text_file_off + 2; // after 2 bytes of merged .text
    try std.testing.expectEqual(0xe8, exe_bytes[stub_off]); // call rel32
    // disp = main_addr(0) - start_offset(2) - 5 = -7 = 0xfffffff9 (little-endian: f9 ff ff ff).
    try std.testing.expectEqualSlices(u8, exe_bytes[stub_off + 1..stub_off + 5], &[_]u8{ 0xf9, 0xff, 0xff, 0xff });
}

test "linkObject writes a PE executable whose entry main calls _main" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_pe = @import("obj_pe.zig");

    // Program object: _main (ret) in .text, puts undefined.
    var prog_text = [_]u8{ 0xc3 };
    const prog_symbols = &.{
        obj_pe.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = true },
        obj_pe.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_pe.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_pe.Reloc{},
    };
    var prog_w = obj_pe.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_link_pe_prog.obj";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts (nop) defined in .text.
    const rt_text = [_]u8{ 0x90 };
    const rt_symbols = &.{
        obj_pe.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_pe.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_pe.Reloc{},
    };
    var rt_w = obj_pe.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_link_pe_rt.obj";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    const exe_path = "ferro_link_pe.exe";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const opts = defaultLinkOptions(.windows_x86_64);
    try linkObject(io, gpa, prog_path, rt_path, exe_path, opts);

    const exe_bytes = try std.Io.Dir.cwd().readFileAlloc(io, exe_path, gpa, .unlimited);
    defer gpa.free(exe_bytes);

    // DOS header + e_lfanew pointing at the PE signature.
    try std.testing.expectEqualSlices(u8, exe_bytes[0..2], &[_]u8{ 'M', 'Z' });
    try std.testing.expectEqual(64, readU32(exe_bytes, 60));

    // PE signature + COFF file header.
    try std.testing.expectEqualSlices(u8, exe_bytes[64..68], &[_]u8{ 'P', 'E', 0, 0 });
    try std.testing.expectEqual(0x8664, readU16(exe_bytes, 68)); // machine = AMD64

    // Optional header (PE32+): magic 0x20b at offset 88.
    try std.testing.expectEqual(0x20b, readU16(exe_bytes, 88)); // magic = PE32+
    // AddressOfEntryPoint at optional header + 16 = 104.
    // image_base low32 (0x40000000) + stub_rel_addr(0x1002) = 0x40001002.
    try std.testing.expectEqual(0x40001002, readU32(exe_bytes, 104));

    // .text raw data at file offset size_of_headers = alignUp(448, 512) = 512.
    // merged .text = prog(1 byte ret) + rt(1 byte nop) = 2 bytes.
    const text_file_off: u64 = 512;
    try std.testing.expectEqual(0xc3, exe_bytes[text_file_off]); // program byte (ret)
    try std.testing.expectEqual(0x90, exe_bytes[text_file_off + 1]); // runtime byte (nop)
    // main stub right after: E8 disp32 + C3 ret.
    const stub_off = text_file_off + 2;
    try std.testing.expectEqual(0xe8, exe_bytes[stub_off]); // E8 = call rel32
    // disp = main_rel_addr(0) - stub_rel_addr(0x1002) - 5 = -4103 = 0xffffeff9 (LE: f9 ef ff ff).
    try std.testing.expectEqualSlices(u8, exe_bytes[stub_off + 1..stub_off + 5], &[_]u8{ 0xf9, 0xef, 0xff, 0xff });
    try std.testing.expectEqual(0xc3, exe_bytes[stub_off + 5]); // C3 = ret
}

test "writeExecutablePe produces a PE executable whose main calls _main" {
    const gpa = std.testing.allocator;

    // Merged image: _main at relative address 10, 1 byte of program .text.
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    try symbols.put("_main", .{ .section = ".text", .value = 10 });

    var prog_text = [_]u8{ 0x90 };
    var prog_data = [_]u8{};
    var image = MergedImage{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = symbols,
    };

    const buf = try writeExecutablePe(&image, 10, .console, gpa);
    defer gpa.free(buf);

    // DOS header + e_lfanew pointing at the PE signature.
    try std.testing.expectEqualSlices(u8, buf[0..2], &[_]u8{ 'M', 'Z' });
    try std.testing.expectEqual(64, readU32(buf, 60)); // e_lfanew = offset to "PE\0\0"

    // PE signature + COFF file header.
    try std.testing.expectEqualSlices(u8, buf[64..68], &[_]u8{ 'P', 'E', 0, 0 });
    try std.testing.expectEqual(0x8664, readU16(buf, 68)); // machine = AMD64

    // Optional header (PE32+): magic 0x20b at offset 88.
    try std.testing.expectEqual(0x20b, readU16(buf, 88)); // magic = PE32+
    // AddressOfEntryPoint at optional header + 16 = 104.
    try std.testing.expectEqual(0x40001001, readU32(buf, 104)); // image_base(0x140000000) low32 + stub_rel_addr(0x1001)

    // .text raw data at file offset size_of_headers = alignUp(448, 512) = 512.
    const text_file_off: u64 = 512;
    try std.testing.expectEqual(0x90, buf[text_file_off]); // program byte
    // main stub right after: E8 disp32 + C3 ret.
    const stub_off = text_file_off + 1;
    try std.testing.expectEqual(0xe8, buf[stub_off]); // E8 = call rel32
    // disp = main_rel_addr(10) - stub_rel_addr(0x1001) - 5 = -4092 = 0xfffff004 (LE: 04 f0 ff ff).
    try std.testing.expectEqualSlices(u8, buf[stub_off + 1..stub_off + 5], &[_]u8{ 0x04, 0xf0, 0xff, 0xff });
    try std.testing.expectEqual(0xc3, buf[stub_off + 5]); // C3 = ret
}
