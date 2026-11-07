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
        const obj = try readArchiveObject(io, gpa, path);
        owned = false;
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
    return @as(u32, bytes[off])
        | (@as(u32, bytes[off + 1]) << 8)
        | (@as(u32, bytes[off + 2]) << 16)
        | (@as(u32, bytes[off + 3]) << 24);
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

/// Read a NUL-terminated string from `strtab` at `off`.
fn cstr(strtab: []const u8, off: usize) []const u8 {
    if (off >= strtab.len) return "";
    const end = std.mem.indexOf(u8, strtab[off..], &[_]u8{0}) orelse strtab.len - off;
    return strtab[off..off + end];
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
const CoffRelocRel32: u16 = 4;  // IMAGE_REL_AMD64_REL32

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
                // PE/COFF addend is implicit at the site. For PC32 relocations,
                // the addend must be -4: the call displacement is relative to
                // the next instruction (after the 4-byte placeholder), but the
                // relocation site is at the placeholder itself.
                .addend = if (kind == .pc32) -4 else 0,
            });
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
    return coffSymName(sym_data[soff..soff + 8], strtab);
}

/// Read a NUL-terminated name from the string table at `offset` (offset into
/// the string table measured from its first byte, which includes the 4-byte
/// size dword).
fn strtabName(strtab: []const u8, offset: u64) []const u8 {
    if (offset >= @as(u64, strtab.len)) return "";
    const end = std.mem.indexOf(u8, strtab[offset..], &[_]u8{0}) orelse strtab.len - offset;
    return strtab[offset..offset + end];
}

// ============================================================================
// Platform archive reader
// ============================================================================

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

    var off: usize = 8;
    while (off + ArHeaderSize <= file_bytes.len) {
        const hdr = file_bytes[off..off + ArHeaderSize];
        const size_field = hdr[48..58];
        const size_str = std.mem.trim(u8, size_field, " ");
        const size = std.fmt.parseInt(u64, size_str, 10) catch return error.ObjectReadFailed;
        const member_data_start = off + ArHeaderSize;
        var member_data: []u8 = undefined;
        if (member_data_start + size > file_bytes.len) {
            member_data = file_bytes[member_data_start..];
        } else {
            member_data = file_bytes[member_data_start..member_data_start + size];
        }
        // Members are padded to a 2-byte boundary.
        off = member_data_start + ((size + 1) / 2 * 2);

        if (member_data.len == 0) continue;

        if (member_data.len >= 2 and readU16(member_data, 0) == 0x8664) {
            const member = try readCoffObjectFromBytes(
                gpa,
                std.fmt.allocPrint(gpa, "{s}[member]", .{path}) catch return error.ObjectReadFailed,
                member_data,
            );
            try members.append(gpa, member);
        } else if (member_data.len >= 4 and std.mem.eql(u8, member_data[0..4], &[_]u8{0x7f, 'E', 'L', 'F'})) {
            const member = try readElfObject(
                gpa,
                std.fmt.allocPrint(gpa, "{s}[member]", .{path}) catch return error.ObjectReadFailed,
                member_data,
            );
            try members.append(gpa, member);
        }
        // else: non-object archive member (symbol/string table) — skip.
    }

    if (members.items.len == 0) return error.ObjectReadFailed;

    // ---- Pass 2: merge into one Object with .text (offset 0) then .data. ----
    var obj = Object{
        .path = path,
        .format = .pe_coff,
        .file_bytes = file_bytes,
        .sections = .empty,
        .symbols = .empty,
        .relocations = .empty,
    };
    errdefer obj.deinit(gpa);

    // Concatenate section contents.
    var merged_text: []u8 = undefined;
    var merged_data: []u8 = undefined;
    {
        var text_len: u64 = 0;
        var data_len: u64 = 0;
        for (members.items) |m| {
            for (m.sections.items) |sec| {
                if (std.mem.eql(u8, sec.name, ".text")) {
                    text_len += sec.size;
                } else if (std.mem.eql(u8, sec.name, ".data") or std.mem.eql(u8, sec.name, ".rdata")) {
                    data_len += sec.size;
                }
            }
        }
        if (text_len > 0) {
            merged_text = try gpa.alloc(u8, text_len);
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
        if (data_len > 0) {
            merged_data = try gpa.alloc(u8, data_len);
            var pos: u64 = 0;
            for (members.items) |m| {
                for (m.sections.items) |sec| {
                    if (std.mem.eql(u8, sec.name, ".data") or std.mem.eql(u8, sec.name, ".rdata")) {
                        for (sec.content, 0..) |b, i| merged_data[pos + @as(usize, i)] = b;
                        pos += sec.size;
                    }
                }
            }
        }
    }

    // Record cumulative text/data offset before each member.
    var cum_text: u64 = 0;
    var cum_data: u64 = 0;

    // Sections.
    try obj.sections.append(gpa, .{
        .name = try gpa.dupe(u8, ".text"),
        .offset = 0,
        .size = @as(u64, merged_text.len),
        .flags = 0,
        .type_ = 0,
        .content = merged_text,
    });
    if (merged_data.len > 0) {
        try obj.sections.append(gpa, .{
            .name = try gpa.dupe(u8, ".data"),
            .offset = 0,
            .size = @as(u64, merged_data.len),
            .flags = 0,
            .type_ = 0,
            .content = merged_data,
        });
    }

    // Symbols.
    for (members.items) |m| {
        var member_data_size: u64 = 0;
        for (m.sections.items) |sec| {
            if (std.mem.eql(u8, sec.name, ".data")) member_data_size += sec.size;
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
            } else if (std.mem.eql(u8, sym.section.?, ".data")) {
                sec = ".data";
                value = cum_data + sym.value;
            } else if (std.mem.eql(u8, sym.section.?, ".rdata")) {
                sec = ".data";
                value = cum_data + member_data_size + sym.value;
            } else {
                continue;
            }
            try obj.symbols.append(gpa, .{
                .name = try gpa.dupe(u8, sym.name),
                .section = sec,
                .value = value,
                .size = sym.size,
                .binding = sym.binding,
            });
        }
        // Advance cumulative offsets past this member's sections.
        for (m.sections.items) |sec| {
            if (std.mem.eql(u8, sec.name, ".text")) {
                cum_text += sec.size;
            } else if (std.mem.eql(u8, sec.name, ".data") or std.mem.eql(u8, sec.name, ".rdata")) {
                cum_data += sec.size;
            }
        }
    }

    // Relocations. Only carry over relocations that target a section we
    // actually merged (.text or .data). Relocations against .rdata, .xdata,
    // .pdata, etc. are dropped: Ferro's object model has no representation
    // for those sections, and applying them to .data corrupts appended data
    // such as the PE import table.
    cum_text = 0;
    cum_data = 0;
    for (members.items) |m| {
        var member_data_size: u64 = 0;
        for (m.sections.items) |sec| {
            if (std.mem.eql(u8, sec.name, ".data")) member_data_size += sec.size;
        }
        for (m.relocations.items) |rel| {
            const sec_name = if (rel.section_idx > 0 and rel.section_idx <= m.sections.items.len)
                m.sections.items[rel.section_idx - 1].name
            else
                "";
            if (!std.mem.eql(u8, sec_name, ".text") and !std.mem.eql(u8, sec_name, ".data") and !std.mem.eql(u8, sec_name, ".rdata")) continue;
            // Remap to Ferro's two-section model: .text -> 1, .data -> 2.
            const new_section_idx: u16 = if (std.mem.eql(u8, sec_name, ".text")) 1 else 2;
            const off_base = if (new_section_idx == 1) cum_text else (cum_data + (if (std.mem.eql(u8, sec_name, ".rdata")) member_data_size else 0));
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
            } else if (std.mem.eql(u8, sec.name, ".data") or std.mem.eql(u8, sec.name, ".rdata")) {
                cum_data += sec.size;
            }
        }
    }

    // Release per-member containers now that their data has been merged.
    for (members.items) |*m| {
        m.sections.deinit(gpa);
        m.symbols.deinit(gpa);
        m.relocations.deinit(gpa);
        if (m.format == .pe_coff) gpa.free(m.file_bytes);
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
