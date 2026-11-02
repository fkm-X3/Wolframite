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
pub const MergedImage = struct {
    pub fn deinit(_: *MergedImage, _: Allocator) void {}
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
                .offset = r_offset,
                .symbol = sym_name,
                .kind = kind,
                .addend = r_addend,
            });
            _ = target_sec_idx;
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
