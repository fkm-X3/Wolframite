//! Ferro object reader — ELF64, PE/COFF, and platform archive containers.
//!
//! Reads Tungsten-emitted object files (ELF64 on Linux, PE/COFF on Windows)
//! plus the Wolframite runtime archive into a shared `Object` model defined in
//! `ferro_types.zig`. The format is auto-detected from the file's magic bytes;
//! callers never have to state it explicitly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const Object = ferro_types.Object;
const Section = ferro_types.Section;
const Symbol = ferro_types.Symbol;
const Relocation = ferro_types.Relocation;
const Binding = ferro_types.Binding;
const RelocKind = ferro_types.RelocKind;
const ObjectFormat = ferro_types.ObjectFormat;
const LinkError = ferro_types.LinkError;

// ============================================================================
// Entry point
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

    // Platform archive container (GNU ar `!<arch>\n`): e.g. `wfr_std.lib`.
    // Unwrap and merge the contained object members.
    if (file_bytes.len >= 8 and std.mem.eql(u8, file_bytes[0..8], "!<arch>\n")) {
        gpa.free(file_bytes);
        owned = false;
        const obj = try readArchiveObject(io, gpa, path);
        return obj;
    }

    // COFF object files have no magic bytes; they start with the COFF file
    // header whose first field is the machine type. x86-64 = 0x8664.
    if (file_bytes.len >= 2 and readU16(file_bytes, 0) == 0x8664) {
        const obj = try readCoffObjectFromBytes(gpa, path, file_bytes);
        gpa.free(file_bytes);
        owned = false; // original freed; `obj` owns its own copy
        return obj;
    }

    return error.ObjectReadFailed;
}

// ============================================================================
// Byte helpers
// ============================================================================

pub fn readU16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

pub fn readU32(bytes: []const u8, off: usize) u32 {
    return @as(u32, bytes[off]) | (@as(u32, bytes[off + 1]) << 8) | (@as(u32, bytes[off + 2]) << 16) | (@as(u32, bytes[off + 3]) << 24);
}

pub fn readU64(bytes: []const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        v |= @as(u64, bytes[off + @as(usize, i)]) << i * 8;
    }
    return v;
}

pub fn readI64(bytes: []const u8, off: usize) i64 {
    return @bitCast(readU64(bytes, off));
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

const StBindingLocal: u8 = 0;
const StBindingGlobal: u8 = 1;
const StBindingWeak: u8 = 2;

const RelX86_64_64: u32 = 1;
const RelX86_64_PC32: u32 = 2;
const RelX86_64_PLT32: u32 = 4;
const RelX86_64_32: u32 = 10;
const RelX86_64_32S: u32 = 11;
const RelX86_64_Tpoff32: u32 = 23;

/// Read a NUL-terminated string from `strtab` at `off`.
fn cstr(strtab: []const u8, off: usize) []const u8 {
    if (off >= strtab.len) return "";
    const end = std.mem.indexOf(u8, strtab[off..], &[_]u8{0}) orelse strtab.len - off;
    return strtab[off .. off + end];
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
            .alignment = @max(1, hdr.addralign),
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
                RelX86_64_PC32, RelX86_64_PLT32 => .pc32,
                RelX86_64_64 => .addr64,
                RelX86_64_32, RelX86_64_32S => .abs32,
                RelX86_64_Tpoff32 => .tpoff32,
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

// ============================================================================
// PE/COFF object reader
// ============================================================================

const CoffSectionText: u16 = 1;
const CoffSectionData: u16 = 2;
const CoffSectionBss: u16 = 3;
const CoffSectionUndefined: u16 = 0;

const CoffSymSize: u64 = 18;
const CoffAuxSectionSize: u64 = 18;
const CoffRelocSize: u64 = 10;

const CoffRelocAddr64: u16 = 1; // IMAGE_REL_AMD64_ADDR64
const CoffRelocRel32: u16 = 4; // IMAGE_REL_AMD64_REL32
const CoffRelocSecrel: u16 = 11; // IMAGE_REL_AMD64_SECREL

/// Read a PE/COFF object from `bytes` (a raw object, not an archive).
fn readCoffObjectFromBytes(gpa: Allocator, path: []const u8, bytes: []const u8) !Object {
    if (bytes.len < 20) return error.ObjectReadFailed;

    const num_sections = @as(u64, @intCast(readU16(bytes, 2)));
    const ptr_to_symtab = readU32(bytes, 8);
    const num_symbols = readU32(bytes, 12);

    if (num_sections == 0) return error.ObjectReadFailed;
    if (20 + num_sections * 40 > @as(u64, bytes.len)) return error.ObjectReadFailed;

    var obj = Object{
        .path = path,
        .format = .pe_coff,
        .file_bytes = try gpa.dupe(u8, bytes),
        .sections = .empty,
        .symbols = .empty,
        .relocations = .empty,
    };
    errdefer obj.deinit(gpa);

    var empty: [0]u8 = undefined;
    for (0..num_sections) |si| {
        const off = 20 + @as(u64, si) * 40;
        const sec_data = obj.file_bytes[@intCast(off)..@intCast(off + 40)];
        const raw_size = readU32(sec_data, 16);
        const raw_ptr = readU32(sec_data, 20);
        const num_relocs = @as(u64, @intCast(readU16(sec_data, 32)));
        const characteristics = readU32(sec_data, 36);
        const content = if (raw_size == 0) empty[0..] else obj.file_bytes[@intCast(raw_ptr)..@intCast(raw_ptr + raw_size)];
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

    var strtab: []const u8 = empty[0..];
    var sym_data: []const u8 = empty[0..];
    if (ptr_to_symtab != 0 and num_symbols != 0) {
        const strtab_start = @as(u64, ptr_to_symtab) + num_symbols * CoffSymSize;
        if (strtab_start + 4 <= @as(u64, bytes.len)) {
            // First 4 bytes of the string table are its total size. Name
            // offsets are relative to the string table start (including those
            // 4 bytes), so strtab must cover them.
            strtab = obj.file_bytes[@intCast(strtab_start)..];
        }
        sym_data = obj.file_bytes[@intCast(ptr_to_symtab)..@intCast(ptr_to_symtab + num_symbols * CoffSymSize)];
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

    for (0..num_sections) |si| {
        const off = 20 + @as(u64, si) * 40;
        const sec_data = obj.file_bytes[@intCast(off)..@intCast(off + 40)];
        const reloc_ptr = readU32(sec_data, 24);
        const num_relocs = @as(u64, @intCast(readU16(sec_data, 32)));
        if (num_relocs == 0) continue;
        if (reloc_ptr + num_relocs * CoffRelocSize > @as(u64, bytes.len)) return error.ObjectReadFailed;
        const reloc_data = bytes[@intCast(reloc_ptr)..@intCast(reloc_ptr + num_relocs * CoffRelocSize)];
        var ri: u64 = 0;
        while (ri < num_relocs) : (ri += 1) {
            const roff = ri * CoffRelocSize;
            const r_offset = readU32(reloc_data, @intCast(roff + 0));
            const sym_index = readU32(reloc_data, @intCast(roff + 4));
            const r_type = readU16(reloc_data, @intCast(roff + 8));
            var sym_name: []const u8 = "";
            if (sym_index < num_symbols) sym_name = coffSymNameAt(sym_data, strtab, sym_index);
            // PE/COFF addend is implicit at the site. For PC32 relocations,
            // the addend must be -4: the call displacement is relative to
            // the next instruction (after the 4-byte placeholder), but the
            // relocation site is at the placeholder itself.
            switch (r_type) {
                CoffRelocAddr64 => try obj.relocations.append(gpa, .{
                    .section_idx = @truncate(si + 1), // COFF sections are 1-based
                    .offset = r_offset,
                    .symbol = sym_name,
                    .kind = .addr64,
                    .addend = 0,
                }),
                CoffRelocRel32 => try obj.relocations.append(gpa, .{
                    .section_idx = @truncate(si + 1),
                    .offset = r_offset,
                    .symbol = sym_name,
                    .kind = .pc32,
                    .addend = -4,
                }),
                CoffRelocSecrel => try obj.relocations.append(gpa, .{
                    .section_idx = @truncate(si + 1),
                    .offset = r_offset,
                    .symbol = sym_name,
                    .kind = .secrel32,
                    .addend = 0,
                }),
                // Anything else cannot be represented in Ferro's model;
                // failing loudly beats silently writing garbage.
                else => return error.ObjectReadFailed,
            }
        }
    }

    return obj;
}

/// Read a PE/COFF object file (raw, not an archive).
fn readCoffObject(gpa: Allocator, path: []const u8, file_bytes: []u8) !Object {
    return readCoffObjectFromBytes(gpa, path, file_bytes);
}

/// Read a short (inline) COFF symbol/section name from an 8-byte field.
fn coffShortName(field: []const u8, off: usize) []const u8 {
    const nul = std.mem.indexOf(u8, field[off .. off + 8], &[_]u8{0}) orelse 8;
    return field[off .. off + nul];
}

/// Look up a section name by its 1-based COFF section number.
fn secNameByIndex(sections: std.ArrayList(Section), number: u16) ?[]const u8 {
    const sec_count: u16 = @intCast(sections.items.len);
    if (number == 0 or number > sec_count) return null;
    return sections.items[@as(usize, number) - 1].name;
}

/// Read a COFF symbol name, handling the string table for long names.
///
/// For a long name, the 8-byte field holds a 32-bit little-endian offset into
/// the string table with the high bit (0x80000000) set; bytes 4..7 are zero.
/// `strtab` must cover the string table starting at its first byte (including
/// the 4-byte size dword), so `offset` is measured from there.
fn coffSymName(field: []const u8, strtab: []const u8) []const u8 {
    const dword = readU32(field, 0);
    // Standard COFF long name: high bit of the offset dword is set.
    if (dword & 0x8000_0000 != 0) {
        const offset = @as(u64, dword & 0x7FFF_FFFF);
        return strtabName(strtab, offset);
    }
    // Zig's object writer stores the plain (high-bit clear) string-table
    // offset in bytes 4..7 with bytes 0..3 zeroed (no high-bit marker).
    // Detect that here so symbols from `zig build`-produced archives resolve.
    if (dword == 0) {
        const zig_offset = readU32(field, 4);
        if (zig_offset != 0) {
            return strtabName(strtab, @as(u64, zig_offset));
        }
    }
    // Short name: NUL-terminated within the 8-byte field.
    const nul = std.mem.indexOf(u8, field, &[_]u8{0});
    if (nul) |n| return field[0..n];
    return field;
}

/// Read a COFF symbol name by symbol-table index (for relocations).
fn coffSymNameAt(sym_data: []const u8, strtab: []const u8, index: u32) []const u8 {
    const soff = @as(usize, index) * 18;
    if (soff + 8 > sym_data.len) return "";
    return coffSymName(sym_data[soff .. soff + 8], strtab);
}

/// Read a NUL-terminated name from the string table at `offset` (offset into
/// the string table measured from its first byte, which includes the 4-byte
/// size dword).
fn strtabName(strtab: []const u8, offset: u64) []const u8 {
    if (offset >= @as(u64, strtab.len)) return "";
    const end = std.mem.indexOf(u8, strtab[offset..], &[_]u8{0}) orelse strtab.len - offset;
    return strtab[offset .. offset + end];
}

// ============================================================================
// Platform archive reader
// ============================================================================

fn isDataLikeSection(name: []const u8) bool {
    return std.mem.eql(u8, name, ".data") or
        std.mem.eql(u8, name, ".rdata") or
        std.mem.eql(u8, name, ".rodata") or
        std.mem.eql(u8, name, ".data.rel.ro");
}

fn isBssLikeSection(name: []const u8) bool {
    return std.mem.eql(u8, name, ".bss");
}

/// TLS is never folded into process-global data. COFF spells the initialized
/// template `.tls$`; ELF splits it into `.tdata` and zero-filled `.tbss`.
fn isTlsDataSection(name: []const u8) bool {
    return std.mem.eql(u8, name, ".tls$") or std.mem.eql(u8, name, ".tdata");
}

fn isTlsBssSection(name: []const u8) bool {
    return std.mem.eql(u8, name, ".tbss");
}

fn tlsSectionAlignment(sec: Section) u64 {
    // Zig's COFF writer does not set IMAGE_SCN_ALIGN_* on .tls$, although its
    // variables use their natural x86_64 alignment. Eight is a conservative
    // floor and over-alignment does not change SECREL semantics.
    return @max(8, sec.alignment);
}

fn alignTlsOffset(offset: u64, alignment: u64) u64 {
    return std.mem.alignForward(u64, offset, alignment);
}

/// Read a relocatable object file, transparently unwrapping platform archive
/// containers (ELF `ar` / COFF `.lib`) so callers can pass either a bare
/// object or an archive such as `wfr_std.lib`.
///
/// Archive members that are themselves valid ELF64 or PE/COFF objects are
/// parsed and merged into a single `Object`; non-object members (symbol and
/// string tables) are skipped. Symbol values and relocation offsets are
/// rebased so the merged object has `.text` at offset 0 followed by `.data`.
pub fn readArchiveObject(io: std.Io, gpa: Allocator, path: []const u8) !Object {
    var file_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        std.Io.File.OpenError.FileNotFound, std.Io.File.OpenError.AccessDenied => return error.ObjectMissing,
        else => return error.ObjectReadFailed,
    };
    var owned: bool = true;
    defer if (owned) gpa.free(file_bytes);

    if (file_bytes.len < 16) return error.ObjectReadFailed;
    if (!std.mem.eql(u8, file_bytes[0..8], "!<arch>\n")) return error.ObjectReadFailed;

    const ArHeaderSize: usize = 60;

    // ---- Pass 1: parse each object member into a standalone Object. ----
    var members = std.ArrayList(Object).empty;
    defer members.deinit(gpa);
    // On any error after this point, free every member parsed so far (their
    // buffers and, on the member-parse error path, the member path string).
    errdefer {
        for (members.items) |*m| {
            gpa.free(m.path);
            m.deinit(gpa);
        }
    }

    var off: usize = 8;
    while (off + ArHeaderSize <= file_bytes.len) {
        const hdr = file_bytes[off .. off + ArHeaderSize];
        const size_field = hdr[48..58];
        const size_str = std.mem.trim(u8, size_field, " ");
        const size = std.fmt.parseInt(u64, size_str, 10) catch return error.ObjectReadFailed;
        const member_data_start = off + ArHeaderSize;
        var member_data: []u8 = undefined;
        if (member_data_start + size > file_bytes.len) {
            member_data = file_bytes[member_data_start..];
        } else {
            member_data = file_bytes[member_data_start .. member_data_start + size];
        }
        // Members are padded to a 2-byte boundary.
        off = member_data_start + ((size + 1) / 2 * 2);

        if (member_data.len == 0) continue;

        if (member_data.len >= 2 and readU16(member_data, 0) == 0x8664) {
            const member_path = std.fmt.allocPrint(gpa, "{s}[member]", .{path}) catch return error.ObjectReadFailed;
            if (readCoffObjectFromBytes(gpa, member_path, member_data)) |member| {
                try members.append(gpa, member);
            } else |err| {
                gpa.free(member_path);
                return err;
            }
        } else if (member_data.len >= 4 and std.mem.eql(u8, member_data[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' })) {
            const member_path = std.fmt.allocPrint(gpa, "{s}[member]", .{path}) catch return error.ObjectReadFailed;
            if (readElfObject(gpa, member_path, member_data)) |member| {
                try members.append(gpa, member);
            } else |err| {
                gpa.free(member_path);
                return err;
            }
        }
        // else: non-object archive member (symbol/string table) — skip.
    }

    if (members.items.len == 0) return error.ObjectReadFailed;

    // ---- Pass 2: merge into one Object with canonical text/data/TLS. ----
    var obj = Object{
        .path = path,
        .format = members.items[0].format,
        .file_bytes = file_bytes,
        .sections = .empty,
        .symbols = .empty,
        .relocations = .empty,
        .owned_text = null,
        .owned_data = null,
        .owned_tls = null,
        .owns_symbol_names = true,
    };
    errdefer obj.deinit(gpa);

    // Concatenate section contents.
    var merged_text: []u8 = undefined;
    var merged_data: []u8 = undefined;
    var merged_tls: []u8 = undefined;
    var merged_tls_alignment: u64 = 8;
    {
        var text_len: u64 = 0;
        var data_len: u64 = 0;
        var tls_len: u64 = 0;
        for (members.items) |m| {
            for (m.sections.items) |sec| {
                if (std.mem.eql(u8, sec.name, ".text")) {
                    text_len += sec.size;
                } else if (isDataLikeSection(sec.name)) {
                    data_len += sec.size;
                } else if (isTlsDataSection(sec.name)) {
                    merged_tls_alignment = @max(merged_tls_alignment, tlsSectionAlignment(sec));
                    tls_len = alignTlsOffset(tls_len, tlsSectionAlignment(sec));
                    tls_len += sec.size;
                }
            }
        }
        merged_text = try gpa.alloc(u8, text_len);
        if (text_len > 0) {
            var pos: u64 = 0;
            for (members.items) |m| {
                for (m.sections.items) |sec| {
                    if (std.mem.eql(u8, sec.name, ".text")) {
                        for (sec.content, 0..) |b, i| merged_text[pos + @as(usize, i)] = b;
                        pos += sec.size;
                    }
                }
            }
        }
        merged_data = try gpa.alloc(u8, data_len);
        if (data_len > 0) {
            var pos: u64 = 0;
            for (members.items) |m| {
                for (m.sections.items) |sec| {
                    if (isDataLikeSection(sec.name)) {
                        for (sec.content, 0..) |b, i| merged_data[pos + @as(usize, i)] = b;
                        pos += sec.size;
                    }
                }
            }
        }
        merged_tls = try gpa.alloc(u8, tls_len);
        @memset(merged_tls, 0);
        if (tls_len > 0) {
            var pos: u64 = 0;
            for (members.items) |m| {
                for (m.sections.items) |sec| {
                    if (isTlsDataSection(sec.name)) {
                        pos = alignTlsOffset(pos, tlsSectionAlignment(sec));
                        for (sec.content, 0..) |b, i| merged_tls[pos + @as(usize, i)] = b;
                        pos += sec.size;
                    }
                }
            }
        }
    }

    // Record cumulative text/data/TLS offsets before each member.
    var cum_text: u64 = 0;
    var cum_data: u64 = 0;
    var cum_tls: u64 = 0;
    var cum_tbss: u64 = 0;

    obj.owned_text = merged_text;
    obj.owned_data = merged_data;
    obj.owned_tls = merged_tls;

    // Sections.
    try obj.sections.append(gpa, .{
        .name = ".text",
        .offset = 0,
        .size = @as(u64, merged_text.len),
        .flags = 0,
        .type_ = 0,
        .content = merged_text,
    });
    if (merged_data.len > 0) {
        try obj.sections.append(gpa, .{
            .name = ".data",
            .offset = 0,
            .size = @as(u64, merged_data.len),
            .flags = 0,
            .type_ = 0,
            .content = merged_data,
        });
    }
    if (merged_tls.len > 0) {
        try obj.sections.append(gpa, .{
            .name = ".tls",
            .offset = 0,
            .size = @as(u64, merged_tls.len),
            .flags = 0,
            .type_ = 0,
            .alignment = merged_tls_alignment,
            .content = merged_tls,
        });
    }
    // Process-global and thread-local zero-filled sections stay distinct.
    var total_bss: u64 = 0;
    var total_tbss: u64 = 0;
    var merged_tbss_alignment: u64 = 8;
    for (members.items) |m| {
        for (m.sections.items) |sec| {
            if (isBssLikeSection(sec.name)) {
                total_bss += sec.size;
            } else if (isTlsBssSection(sec.name)) {
                total_tbss = alignTlsOffset(total_tbss, tlsSectionAlignment(sec));
                total_tbss += sec.size;
                merged_tbss_alignment = @max(merged_tbss_alignment, tlsSectionAlignment(sec));
            }
        }
    }
    var empty: [0]u8 = undefined;
    if (total_bss > 0) {
        try obj.sections.append(gpa, .{
            .name = ".bss",
            .offset = 0,
            .size = total_bss,
            .flags = 0,
            .type_ = 0,
            .content = empty[0..],
        });
    }
    if (total_tbss > 0) {
        try obj.sections.append(gpa, .{
            .name = ".tbss",
            .offset = 0,
            .size = total_tbss,
            .flags = 0,
            .type_ = 0,
            .alignment = merged_tbss_alignment,
            .content = empty[0..],
        });
    }

    // Symbols. Section-relative TLS offsets are preserved through the merge;
    // they must never become process-global .data addresses.
    for (members.items) |m| {
        var section_data_off = std.StringHashMap(u64).init(gpa);
        defer section_data_off.deinit();
        var section_tls_off = std.StringHashMap(u64).init(gpa);
        defer section_tls_off.deinit();
        var section_tbss_off = std.StringHashMap(u64).init(gpa);
        defer section_tbss_off.deinit();
        var running: u64 = 0;
        var running_tls: u64 = 0;
        var running_tbss: u64 = 0;
        for (m.sections.items) |sec| {
            if (isDataLikeSection(sec.name)) {
                section_data_off.put(sec.name, running) catch {};
                running += sec.size;
            } else if (isTlsDataSection(sec.name)) {
                running_tls = alignTlsOffset(running_tls, tlsSectionAlignment(sec));
                section_tls_off.put(sec.name, running_tls) catch {};
                running_tls += sec.size;
            } else if (isTlsBssSection(sec.name)) {
                running_tbss = alignTlsOffset(running_tbss, tlsSectionAlignment(sec));
                section_tbss_off.put(sec.name, running_tbss) catch {};
                running_tbss += sec.size;
            }
        }
        for (m.symbols.items) |sym| {
            if (sym.name.len == 0) continue;
            var sec: ?[]const u8 = null;
            var value: u64 = 0;
            if (sym.section == null) {
                sec = null;
                value = 0;
            } else if (std.mem.eql(u8, sym.section.?, ".text")) {
                sec = ".text";
                value = cum_text + sym.value;
            } else if (isDataLikeSection(sym.section.?)) {
                sec = ".data";
                const base = section_data_off.get(sym.section.?) orelse 0;
                value = cum_data + base + sym.value;
            } else if (isTlsDataSection(sym.section.?)) {
                sec = ".tls";
                const base = section_tls_off.get(sym.section.?) orelse 0;
                value = cum_tls + base + sym.value;
            } else if (isTlsBssSection(sym.section.?)) {
                sec = ".tbss";
                const base = section_tbss_off.get(sym.section.?) orelse 0;
                value = cum_tbss + base + sym.value;
            } else {
                continue;
            }
            try obj.symbols.append(gpa, .{
                .name = try gpa.dupe(u8, sym.name),
                .section = sec,
                .binding = sym.binding,
                .value = value,
                .size = sym.size,
            });
        }
        // Advance cumulative offsets past this member's sections.
        for (m.sections.items) |sec| {
            if (std.mem.eql(u8, sec.name, ".text")) {
                cum_text += sec.size;
            } else if (isDataLikeSection(sec.name)) {
                cum_data += sec.size;
            }
        }
        cum_tls += running_tls;
        cum_tbss += running_tbss;
    }

    // Carry over relocations whose storage survived the merge. Relocations
    // against discarded metadata (.xdata, .pdata, debug sections, etc.) are
    // not retargeted to unrelated output bytes.
    cum_text = 0;
    cum_data = 0;
    cum_tls = 0;
    for (members.items) |m| {
        var section_data_off = std.StringHashMap(u64).init(gpa);
        defer section_data_off.deinit();
        var section_tls_off = std.StringHashMap(u64).init(gpa);
        defer section_tls_off.deinit();
        var running: u64 = 0;
        var running_tls: u64 = 0;
        for (m.sections.items) |sec| {
            if (isDataLikeSection(sec.name)) {
                section_data_off.put(sec.name, running) catch {};
                running += sec.size;
            } else if (isTlsDataSection(sec.name)) {
                running_tls = alignTlsOffset(running_tls, tlsSectionAlignment(sec));
                section_tls_off.put(sec.name, running_tls) catch {};
                running_tls += sec.size;
            }
        }
        for (m.relocations.items) |rel| {
            // COFF relocation entries use 1-based section numbers; ELF uses
            // 0-based indexes into the section list.
            const member_sec_idx: usize = switch (m.format) {
                .pe_coff => @as(usize, rel.section_idx) - 1,
                .elf64 => @as(usize, rel.section_idx),
            };
            const sec_name = if (member_sec_idx < m.sections.items.len)
                m.sections.items[member_sec_idx].name
            else
                "";
            var new_section_idx: u16 = 0;
            var off_base: u64 = 0;
            if (std.mem.eql(u8, sec_name, ".text")) {
                new_section_idx = 1;
                off_base = cum_text;
            } else if (isDataLikeSection(sec_name)) {
                new_section_idx = 2;
                off_base = cum_data + (section_data_off.get(sec_name) orelse 0);
            } else if (isTlsDataSection(sec_name)) {
                new_section_idx = 3;
                off_base = cum_tls + (section_tls_off.get(sec_name) orelse 0);
            } else {
                continue;
            }
            try obj.relocations.append(gpa, .{
                .section_idx = new_section_idx,
                .offset = rel.offset + off_base,
                .symbol = try gpa.dupe(u8, rel.symbol),
                .kind = rel.kind,
                .addend = rel.addend,
            });
        }
        for (m.sections.items) |sec| {
            if (std.mem.eql(u8, sec.name, ".text")) {
                cum_text += sec.size;
            } else if (isDataLikeSection(sec.name)) {
                cum_data += sec.size;
            }
        }
        cum_tls += running_tls;
    }

    // Release per-member containers now that their data has been merged.
    // `deinit` frees each member's `file_bytes` (ELF members' section
    // contents borrow from it too, and they used to leak here); symbol and
    // relocation names are borrowed, not owned, so they are not freed.
    for (members.items) |*m| {
        gpa.free(m.path);
        m.deinit(gpa);
    }

    owned = false;
    return obj;
}

/// Size of a section named `name` already accumulated in `dst`, or 0.
fn sectionSizeOrZero(dst: *Object, name: []const u8) u64 {
    var total: u64 = 0;
    for (dst.sections.items) |sec| {
        if (std.mem.eql(u8, sec.name, name)) total += sec.size;
    }
    return total;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testPutU32(list: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn testPutU16(list: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

/// Build a minimal COFF object with the section order a Zig-built static
/// library member uses (.bss/.data/.rdata/.text/.tls$) — the layout that
/// exposed the 1-based/0-based relocation merge bug.
fn testBuildCoffMember(gpa: Allocator) ![]u8 {
    var b = std.ArrayList(u8).empty;
    errdefer b.deinit(gpa);

    const data_raw: [8]u8 = @splat(1);
    const rdata_raw: [8]u8 = @splat(2);
    const text_raw: [16]u8 = @splat(0x90);
    const raw_total = data_raw.len + rdata_raw.len + text_raw.len;
    const reloc_total = 3 * 10; // 1 (.rdata) + 2 (.text)
    const num_symbols = 4;
    const header_size = 20 + 5 * 40;
    const ptr_symtab: u32 = header_size + raw_total + reloc_total;
    // String table: 4-byte size dword plus "GetStdHandle\0" — the import
    // name exceeds COFF's 8-byte inline name field, so it is stored as a
    // standard long name (offset with the high bit set).
    const long_name = "GetStdHandle";
    const long_name_off: u32 = 4;
    const strtab_size: u32 = long_name_off + long_name.len + 1;

    // COFF file header.
    try testPutU16(&b, gpa, 0x8664); // machine
    try testPutU16(&b, gpa, 5); // number of sections
    try testPutU32(&b, gpa, 0); // time date stamp
    try testPutU32(&b, gpa, ptr_symtab);
    try testPutU32(&b, gpa, num_symbols);
    try testPutU16(&b, gpa, 0); // size of optional header
    try testPutU16(&b, gpa, 0); // characteristics

    // Section headers. Relocations reference symbols by index:
    // 0 = SomeData (.data), 1 = SomeString (.tls$), 2 = SomeFunc (.text),
    // 3 = GetStdHandle (undefined).
    const sections = [_]struct {
        name: []const u8,
        raw_size: u32,
        raw_ptr: u32,
        reloc_ptr: u32,
        nreloc: u16,
        chars: u32,
    }{
        .{ .name = ".bss", .raw_size = 0, .raw_ptr = 0, .reloc_ptr = 0, .nreloc = 0, .chars = 0xC0000080 },
        .{ .name = ".data", .raw_size = data_raw.len, .raw_ptr = header_size, .reloc_ptr = 0, .nreloc = 0, .chars = 0xC0000040 },
        .{ .name = ".rdata", .raw_size = rdata_raw.len, .raw_ptr = header_size + data_raw.len, .reloc_ptr = ptr_symtab - reloc_total, .nreloc = 1, .chars = 0x40000040 },
        .{ .name = ".text", .raw_size = text_raw.len, .raw_ptr = header_size + data_raw.len + rdata_raw.len, .reloc_ptr = ptr_symtab - 2 * 10, .nreloc = 2, .chars = 0x60000020 },
        .{ .name = ".tls$", .raw_size = 0, .raw_ptr = 0, .reloc_ptr = 0, .nreloc = 0, .chars = 0xC0000040 },
    };
    for (sections) |s| {
        var name: [8]u8 = @splat(0);
        @memcpy(name[0..s.name.len], s.name);
        try b.appendSlice(gpa, &name);
        try testPutU32(&b, gpa, 0); // virtual size
        try testPutU32(&b, gpa, 0); // virtual address
        try testPutU32(&b, gpa, s.raw_size);
        try testPutU32(&b, gpa, s.raw_ptr);
        try testPutU32(&b, gpa, s.reloc_ptr);
        try testPutU32(&b, gpa, 0); // line numbers
        try testPutU16(&b, gpa, s.nreloc);
        try testPutU16(&b, gpa, 0);
        try testPutU32(&b, gpa, s.chars);
    }

    // Section raw data.
    try b.appendSlice(gpa, &data_raw);
    try b.appendSlice(gpa, &rdata_raw);
    try b.appendSlice(gpa, &text_raw);

    // Relocations: .rdata (1): pointer to SomeData; .text (2): call to
    // SomeFunc (REL32) and a TLS-template offset for SomeStr (SECREL).
    try testPutU32(&b, gpa, 0); // .rdata+0
    try testPutU32(&b, gpa, 0); // SomeData
    try testPutU16(&b, gpa, 1); // ADDR64
    try testPutU32(&b, gpa, 0); // .text+0
    try testPutU32(&b, gpa, 2); // SomeFunc
    try testPutU16(&b, gpa, 4); // REL32
    try testPutU32(&b, gpa, 8); // .text+8
    try testPutU32(&b, gpa, 1); // SomeStr
    try testPutU16(&b, gpa, 11); // SECREL

    // Symbol table (18 bytes each, no aux records). "GetStdHandle" uses the
    // long-name form: a dword offset into the string table with the high
    // bit set, followed by four zero bytes.
    const symbols = [_]struct {
        name: []const u8,
        long: bool = false,
        value: u32,
        section: u16,
        storage: u8,
    }{
        .{ .name = "SomeData", .value = 0, .section = 2, .storage = 2 },
        .{ .name = "SomeStr", .value = 0, .section = 5, .storage = 2 },
        .{ .name = "SomeFunc", .value = 0, .section = 4, .storage = 2 },
        .{ .name = long_name, .long = true, .value = 0, .section = 0, .storage = 2 },
    };
    for (symbols) |s| {
        var name: [8]u8 = @splat(0);
        if (s.long) {
            std.mem.writeInt(u32, name[0..4], 0x8000_0000 | long_name_off, .little);
        } else {
            @memcpy(name[0..s.name.len], s.name);
        }
        try b.appendSlice(gpa, &name);
        try testPutU32(&b, gpa, s.value);
        try testPutU16(&b, gpa, s.section);
        try testPutU16(&b, gpa, 0); // type
        try b.append(gpa, s.storage);
        try b.append(gpa, 0); // aux count
    }

    // String table (size dword + the long name).
    try testPutU32(&b, gpa, strtab_size);
    try b.appendSlice(gpa, long_name);
    try b.append(gpa, 0);
    return b.toOwnedSlice(gpa);
}

test "archive merge keeps COFF member relocations (1-based section numbers)" {
    const gpa = testing.allocator;
    const io = testing.io;

    // Wrap the COFF member in an ar archive (no symbol index members).
    const member = try testBuildCoffMember(gpa);
    defer gpa.free(member);
    var lib = std.ArrayList(u8).empty;
    defer lib.deinit(gpa);
    try lib.appendSlice(gpa, "!<arch>\n");
    var hdr: [60]u8 = @splat(' ');
    @memcpy(hdr[0..8], "coff.obj");
    var size_buf: [10]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{member.len});
    @memcpy(hdr[48 .. 48 + size_str.len], size_str);
    hdr[58] = '`';
    hdr[59] = '\n';
    try lib.appendSlice(gpa, &hdr);
    try lib.appendSlice(gpa, member);

    const lib_path = "ferro_reader_coff_merge_test.lib";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lib_path, .data = lib.items });
    defer std.Io.Dir.cwd().deleteFile(io, lib_path) catch {};

    var obj = try readArchiveObject(io, gpa, lib_path);
    defer obj.deinit(gpa);

    // Merged sections: .text (16) then .data (8 .data + 8 .rdata = 16).
    try testing.expectEqual(@as(usize, 2), obj.sections.items.len);
    try testing.expectEqualStrings(".text", obj.sections.items[0].name);
    try testing.expectEqual(@as(u64, 16), obj.sections.items[0].size);
    try testing.expectEqualStrings(".data", obj.sections.items[1].name);
    try testing.expectEqual(@as(u64, 16), obj.sections.items[1].size);

    // Ordinary data symbols keep their rebasing, while TLS symbols retain a
    // canonical TLS-template offset instead of joining .data.
    var found_string = false;
    for (obj.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "SomeStr")) {
            found_string = true;
            try testing.expectEqualStrings(".tls", sym.section.?);
            try testing.expectEqual(@as(u64, 0), sym.value);
        }
        if (std.mem.eql(u8, sym.name, "GetStdHandle")) {
            try testing.expect(sym.section == null);
        }
    }
    try testing.expect(found_string);

    // All three relocations survive with correct merged offsets:
    //   .rdata+0 (pointer to SomeData)  -> .data+8, addr64
    //   .text+0 (call SomeFunc, REL32)  -> .text+0, pc32, addend -4
    //   .text+8 (SomeStr TLS offset)    -> .text+8, secrel32
    try testing.expectEqual(@as(usize, 3), obj.relocations.items.len);
    const rel0 = obj.relocations.items[0];
    try testing.expectEqual(@as(u16, 2), rel0.section_idx);
    try testing.expectEqual(@as(u64, 8), rel0.offset);
    try testing.expectEqualStrings("SomeData", rel0.symbol);
    try testing.expectEqual(RelocKind.addr64, rel0.kind);
    const rel1 = obj.relocations.items[1];
    try testing.expectEqual(@as(u16, 1), rel1.section_idx);
    try testing.expectEqual(@as(u64, 0), rel1.offset);
    try testing.expectEqualStrings("SomeFunc", rel1.symbol);
    try testing.expectEqual(RelocKind.pc32, rel1.kind);
    try testing.expectEqual(@as(i64, -4), rel1.addend);
    const rel2 = obj.relocations.items[2];
    try testing.expectEqual(@as(u16, 1), rel2.section_idx);
    try testing.expectEqual(@as(u64, 8), rel2.offset);
    try testing.expectEqualStrings("SomeStr", rel2.symbol);
    try testing.expectEqual(RelocKind.secrel32, rel2.kind);
}

test "COFF reader rejects unsupported relocation types instead of misapplying them" {
    const gpa = testing.allocator;

    // Same member builder, but corrupt the first .rdata relocation's type
    // (1 = ADDR64) into an unsupported one (2 = ADDR32): the reader must
    // fail loudly rather than silently treat it as an 8-byte pointer.
    const member = try testBuildCoffMember(gpa);
    defer gpa.free(member);
    var bad = member;
    const first_reloc_type = 20 + 5 * 40 + 8 + 8 + 16 + 8; // header + raw + .rdata reloc offset
    bad[first_reloc_type] = 2;
    bad[first_reloc_type + 1] = 0;

    var lib = std.ArrayList(u8).empty;
    defer lib.deinit(gpa);
    try lib.appendSlice(gpa, "!<arch>\n");
    var hdr: [60]u8 = @splat(' ');
    @memcpy(hdr[0..8], "coff.obj");
    var size_buf: [10]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{bad.len});
    @memcpy(hdr[48 .. 48 + size_str.len], size_str);
    hdr[58] = '`';
    hdr[59] = '\n';
    try lib.appendSlice(gpa, &hdr);
    try lib.appendSlice(gpa, bad);

    const lib_path = "ferro_reader_coff_badreloc_test.lib";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = lib.items });
    defer std.Io.Dir.cwd().deleteFile(testing.io, lib_path) catch {};

    try testing.expectError(error.ObjectReadFailed, readArchiveObject(testing.io, gpa, lib_path));
}
