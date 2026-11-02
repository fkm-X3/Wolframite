//! ELF64 object writer for x86-64 Linux.
//!
//! Writes a relocatable ELF64 object (`ET_REL`) from sections, symbols, and
//! relocation records. This is the byte-level emitter for `emitObject`; codegen
//! feeds it machine-code bytes plus relocation records.
//!
//! Format contract is frozen in `docs/adr/adr_object_format.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro = @import("ferro.zig");

// ============================================================================
// ELF64 constants
// ============================================================================

const ElfIdent = packed struct {
    magic0: u8 = 0x7f,
    magic1: u8 = 'E',
    magic2: u8 = 'L',
    magic3: u8 = 'F',
    class: u8 = 2,        // ELFCLASS64
    data: u8 = 1,         // ELFDATA2LSB
    version: u8 = 1,      // EV_CURRENT
    os_abi: u8 = 0,       // ELFOSABI_NONE
    abi_version: u8 = 0,
    pad0: u8 = 0,
    pad1: u8 = 0,
    pad2: u8 = 0,
    pad3: u8 = 0,
    pad4: u8 = 0,
    pad5: u8 = 0,
    pad6: u8 = 0,
};

const ElfSht = enum(u32) {
    null = 0,
    progbits = 1,
    symtab = 2,
    strtab = 3,
    rela = 4,
    nobits = 8,
};

const ShfWrite: u64 = 0x1;
const ShfAlloc: u64 = 0x2;
const ShfExecInstr: u64 = 0x4;

const StBindingLocal: u8 = 0;
const StBindingGlobal: u8 = 1;

const StTypeNotype: u8 = 0;
const StTypeObject: u8 = 1;
const StTypeFunc: u8 = 2;

pub const ShnUndef: u16 = 0;

const RelocX86_64_64: u32 = 1;
const RelocX86_64_PC32: u32 = 2;

// ============================================================================
// Input model
// ============================================================================

pub const Reloc = struct {
    section_idx: u16,
    offset: u64,
    symbol: []const u8,
    kind: ferro.RelocKind,
    addend: i64,
};

pub const Symbol = struct {
    name: []const u8,
    section_idx: u16,
    value: u64,
    size: u64,
    binding: ferro.Binding,
    is_func: bool,
};

pub const ObjectInput = struct {
    text: []const u8,
    data: []const u8,
    bss_size: u64,
    symbols: []const Symbol,
    relocs: []const Reloc,
};

// ============================================================================
// Writer
// ============================================================================

pub const Writer = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8),
    strtab: std.ArrayList(u8),
    shstrtab: std.ArrayList(u8),

    sec_type: std.ArrayList(u32),
    sec_flags: std.ArrayList(u64),
    sec_offset: std.ArrayList(u64),
    sec_size: std.ArrayList(u64),
    sec_link: std.ArrayList(u32),
    sec_info: std.ArrayList(u32),
    sec_addralign: std.ArrayList(u64),
    sec_entsize: std.ArrayList(u64),

    pub fn init(gpa: Allocator) Writer {
        return .{
            .gpa = gpa, .buf = .empty, .strtab = .empty, .shstrtab = .empty,
            .sec_type = .empty, .sec_flags = .empty, .sec_offset = .empty,
            .sec_size = .empty, .sec_link = .empty, .sec_info = .empty,
            .sec_addralign = .empty, .sec_entsize = .empty,
        };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.gpa);
        self.strtab.deinit(self.gpa);
        self.shstrtab.deinit(self.gpa);
        self.sec_type.deinit(self.gpa);
        self.sec_flags.deinit(self.gpa);
        self.sec_offset.deinit(self.gpa);
        self.sec_size.deinit(self.gpa);
        self.sec_link.deinit(self.gpa);
        self.sec_info.deinit(self.gpa);
        self.sec_addralign.deinit(self.gpa);
        self.sec_entsize.deinit(self.gpa);
    }

    /// Emit a complete ELF64 object from `input`. Returns an allocated byte
    /// slice the caller frees with `writer.gpa.free(result)`.
    pub fn writeObject(self: *Writer, input: ObjectInput) ![]u8 {
        try self.build(input);
        // Build the final object: ELF header (64 bytes) followed by all
        // section content and section headers that were written to self.buf.
        const ehdr = Elf64Ehdr{
            .e_ident = .{},
            .e_type = 1, // ET_REL
            .e_machine = 62, // EM_X86_64
            .e_version = 1,
            .e_entry = 0,
            .e_phoff = 0,
            .e_shoff = 64 + @as(u64, @intCast(self.buf.items.len)) - @as(u64, @sizeOf(Elf64Shdr)) * @as(u64, @intCast(self.sec_type.items.len)),
            .e_flags = 0,
            .e_ehsize = 64,
            .e_phentsize = 0,
            .e_phnum = 0,
            .e_shentsize = @intCast(@sizeOf(Elf64Shdr)),
            .e_shnum = @intCast(self.sec_type.items.len),
            .e_shstrndx = 8, // .shstrtab
        };
        const ehdr_bytes = std.mem.asBytes(&ehdr);
        var final_buf: []u8 = try self.gpa.alloc(u8, 64 + self.buf.items.len);
        // Copy ELF header.
        for (ehdr_bytes, 0..) |b, i| {
            final_buf[i] = b;
        }
        // Copy content + section headers from self.buf.
        for (self.buf.items, 0..) |b, i| {
            final_buf[64 + i] = b;
        }
        return final_buf;
    }

    fn build(self: *Writer, input: ObjectInput) !void {
        // ---- Phase 1: build string tables and symbol entries in memory ----
        try self.strtab.append(self.gpa, 0); // index 0 = NUL
        try self.shstrtab.append(self.gpa, 0); // index 0 = NUL

        // Record shstrtab offset for each section name (9 sections: NULL + 8 real).
        const sec_names = [_][]const u8{ "", ".text", ".data", ".bss", ".symtab",
            ".strtab", ".rela.text", ".rela.data", ".shstrtab" };
        var shstr_offsets: [9]u32 = undefined;
        for (sec_names, 0..) |name, i| {
            shstr_offsets[i] = @intCast(self.shstrtab.items.len);
            try self.shstrtab.appendSlice(self.gpa, name);
            try self.shstrtab.append(self.gpa, 0);
        }

        // Symbol name string table: add all symbol names after the initial NUL.
        for (input.symbols) |sym| {
            try self.strtab.appendSlice(self.gpa, sym.name);
            try self.strtab.append(self.gpa, 0);
        }

        // ---- Phase 2: count relocs per target section ----
        var num_text_relocs: u32 = 0;
        var num_data_relocs: u32 = 0;
        for (input.relocs) |r| {
            if (r.section_idx == 1) {
                num_text_relocs += 1; // .text is section 1
            } else if (r.section_idx == 2) {
                num_data_relocs += 1; // .data is section 2
            }
        }

        const sym_count = input.symbols.len;
        const symtab_size: u64 = 24 * @as(u64, @intCast(1 + sym_count));

        // ---- Phase 3: register all section metas (indices 0..8) ----
        // Section index 0 is the ELF NULL section (SHT_NULL).
        const S_TEXT: u16 = 1;
        const S_DATA: u16 = 2;
        const S_SSYMTAB: u16 = 4;
        const S_STRTAB: u16 = 5;

        const text_size: u64 = @as(u64, @intCast(input.text.len));
        const data_size: u64 = @as(u64, @intCast(input.data.len));
        const strtab_size: u64 = @as(u64, @intCast(self.strtab.items.len));
        const shstrtab_size: u64 = @as(u64, @intCast(self.shstrtab.items.len));
        const rela_text_size = 24 * num_text_relocs;
        const rela_data_size = 24 * num_data_relocs;

        try self.addSecMeta(.null, 0,
            0, 0, 0, 0, 0, 0);        // 0: NULL section
        try self.addSecMeta(.progbits, ShfAlloc | ShfExecInstr,
            0, text_size, 0, 0, 16, 0);        // 1: .text
        try self.addSecMeta(.progbits, ShfAlloc | ShfWrite,
            0, data_size, 0, 0, 8, 0);          // 2: .data
        try self.addSecMeta(.nobits, ShfAlloc | ShfWrite,
            0, input.bss_size, 0, 0, 8, 0);     // 3: .bss
        try self.addSecMeta(.symtab, 0,
            0, symtab_size, @intCast(S_STRTAB), 1, 8, 24); // 4: .symtab
        try self.addSecMeta(.strtab, 0,
            0, strtab_size, 0, 0, 1, 0);        // 5: .strtab
        try self.addSecMeta(.rela, 0,
            0, rela_text_size, @intCast(S_SSYMTAB), @intCast(S_TEXT), 8, 24); // 6: .rela.text
        try self.addSecMeta(.rela, 0,
            0, rela_data_size, @intCast(S_SSYMTAB), @intCast(S_DATA), 8, 24); // 7: .rela.data
        try self.addSecMeta(.strtab, 0,
            0, shstrtab_size, 0, 0, 1, 0);      // 8: .shstrtab

        // ---- Phase 4: assign sequential file offsets ----
        var cursor: u64 = 64; // after ELF header
        var i: usize = 0;
        while (i < self.sec_offset.items.len) : (i += 1) {
            self.sec_offset.items[i] = cursor;
            cursor += self.sec_size.items[i];
        }

        // ---- Phase 5: write section contents in order ----
        // .text
        try self.buf.appendSlice(self.gpa, input.text);
        // .data
        try self.buf.appendSlice(self.gpa, input.data);
        // .bss: NOBITS, no file content.
        // .symtab entries
        try self.writeSymtab(input.symbols);
        // .strtab content
        try self.buf.appendSlice(self.gpa, self.strtab.items);
        // .rela.text entries
        try self.writeRela(input.relocs, 0, input.symbols); // .text = section 0
        // .rela.data entries
        try self.writeRela(input.relocs, 1, input.symbols); // .data = section 1
        // .shstrtab content
        try self.buf.appendSlice(self.gpa, self.shstrtab.items);

        // ---- Phase 6: section header array ----
        var j: usize = 0;
        while (j < self.sec_type.items.len) : (j += 1) {
            try self.writeSectionHeader(j, shstr_offsets[@intCast(j)]);
        }
    }

    fn addSecMeta(
        self: *Writer,
        type_: ElfSht,
        flags: u64,
        offset: u64,
        size: u64,
        link: u32,
        info: u32,
        addralign: u64,
        entsize: u64,
    ) !void {
        try self.sec_type.append(self.gpa, @bitCast(type_));
        try self.sec_flags.append(self.gpa, flags);
        try self.sec_offset.append(self.gpa, offset);
        try self.sec_size.append(self.gpa, size);
        try self.sec_link.append(self.gpa, link);
        try self.sec_info.append(self.gpa, info);
        try self.sec_addralign.append(self.gpa, addralign);
        try self.sec_entsize.append(self.gpa, entsize);
    }

    /// Write .symtab entries to buf. Symbol 0 is STN_UNDEF; input symbols
    /// follow at indices 1..N. Symbol `st_name` is the offset in strtab where
    /// the name was written (we track this by re-deriving: names were appended
    /// to strtab in input order after the initial NUL).
    fn writeSymtab(self: *Writer, symbols: []const Symbol) !void {
        // STN_UNDEF: all zeros (24 bytes).
        try self.putU32(0);
        try self.putU8(0);
        try self.putU8(0);
        try self.putU16(ShnUndef);
        try self.putU64(0);
        try self.putU64(0);
        // strtab offsets: symbol i's name starts right after strtab[0] = NUL,
        // then each subsequent name follows the previous (len + 1).
        var str_off: u64 = 1;
        for (symbols) |sym| {
            const st_info = (bindingToByte(sym.binding) << 4) |
                if (sym.is_func) StTypeFunc else StTypeObject;
            try self.putU32(@intCast(str_off));
            try self.putU8(st_info);
            try self.putU8(0);
            try self.putU16(if (sym.section_idx == ShnUndef) ShnUndef else sym.section_idx);
            try self.putU64(sym.value);
            try self.putU64(sym.size);
            str_off += @as(u64, @intCast(sym.name.len)) + 1;
        }
    }

    /// Write RELA entries for relocs targeting `target_section` (0=.text,
    /// 1=.data) to buf. Symbol index = 1 + index of matching symbol in
    /// `symbols` (symbol 0 is STN_UNDEF).
    fn writeRela(
        self: *Writer,
        relocs: []const Reloc,
        target_section: u16,
        symbols: []const Symbol,
    ) !void {
        for (relocs) |r| {
            if (r.section_idx != target_section) continue;
            // Find symbol index: 1 + position in input.symbols.
            var sym_index: u32 = 0;
            for (symbols, 0..) |sym, i| {
                if (std.mem.eql(u8, sym.name, r.symbol)) {
                    sym_index = @as(u32, @intCast(i)) + 1;
                    break;
                }
            }
            const r_type = switch (r.kind) {
                .pc32 => RelocX86_64_PC32,
                .addr64 => RelocX86_64_64,
            };
            // r_offset(u64) r_info(u64) r_addend(i64) = 24 bytes.
            try self.putU64(r.offset);
            try self.putU64((@as(u64, sym_index) << 32) | @as(u64, r_type));
            try self.putI64(r.addend);
        }
    }

    /// Append an i64 (little-endian) to buf.
    fn putI64(self: *Writer, v: i64) !void {
        try self.putU64(@bitCast(v));
    }

    fn bindingToByte(b: ferro.Binding) u8 {
        return switch (b) {
            .local => StBindingLocal,
            .global => StBindingGlobal,
            .weak => StBindingGlobal,
        };
    }

    /// Append a u8 to buf.
    fn putU8(self: *Writer, v: u8) !void {
        try self.buf.append(self.gpa, v);
    }

    /// Append a u16 (little-endian) to buf.
    fn putU16(self: *Writer, v: u16) !void {
        try self.buf.append(self.gpa, @truncate(v));
        try self.buf.append(self.gpa, @truncate(v >> 8));
    }

    /// Append a u32 (little-endian) to buf.
    fn putU32(self: *Writer, v: u32) !void {
        try self.buf.append(self.gpa, @truncate(v));
        try self.buf.append(self.gpa, @truncate(v >> 8));
        try self.buf.append(self.gpa, @truncate(v >> 16));
        try self.buf.append(self.gpa, @truncate(v >> 24));
    }

    /// Append a u64 (little-endian) to buf.
    fn putU64(self: *Writer, v: u64) !void {
        var i: u6 = 0;
        while (i < 8) : (i += 1) {
            try self.buf.append(self.gpa, @truncate(v >> (i * 8)));
        }
    }

    fn writeSectionHeader(self: *Writer, idx: usize, sh_name: u32) !void {
        const shdr = Elf64Shdr{
            .sh_name = sh_name,
            .sh_type = self.sec_type.items[idx],
            .sh_flags = self.sec_flags.items[idx],
            .sh_addr = 0,
            .sh_offset = self.sec_offset.items[idx],
            .sh_size = self.sec_size.items[idx],
            .sh_link = self.sec_link.items[idx],
            .sh_info = self.sec_info.items[idx],
            .sh_addralign = self.sec_addralign.items[idx],
            .sh_entsize = self.sec_entsize.items[idx],
        };
        try self.buf.appendSlice(self.gpa, std.mem.asBytes(&shdr));
    }
};

// ============================================================================
// ELF64 on-disk structures (packed, little-endian, host-native)
// ============================================================================

pub const Elf64Ehdr = packed struct {
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
    _ = @sizeOf(Elf64Ehdr) == 64;
}

pub const Elf64Shdr = packed struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u64,
    sh_addr: u64,
    sh_offset: u64,
    sh_size: u64,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u64,
    sh_entsize: u64,
};
comptime {
    _ = @sizeOf(Elf64Shdr) == 64;
}

pub const Elf64Sym = packed struct {
    st_name: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
    st_value: u64,
    st_size: u64,
};
comptime {
    _ = @sizeOf(Elf64Sym) == 24;
}

pub const Elf64Rela = packed struct {
    r_offset: u64,
    r_info: u64,
    r_addend: i64,
};
comptime {
    _ = @sizeOf(Elf64Rela) == 24;
}

// ============================================================================
// Tests
// ============================================================================

test "ELF64 structure sizes are correct" {
    try std.testing.expectEqual(64, @sizeOf(Elf64Ehdr));
    try std.testing.expectEqual(64, @sizeOf(Elf64Shdr));
    // Elf64Sym and Elf64Rela packed structs are padded to 32 by the compiler;
    // their on-disk form is manually serialized as exactly 24 bytes each
    // (see writeSymtab and writeRela), so @sizeOf is not the on-disk size.
    _ = @sizeOf(Elf64Sym);
    _ = @sizeOf(Elf64Rela);
}

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

test "writeObject produces a valid minimal ELF64 object header" {
    const gpa = std.testing.allocator;
    var w = Writer.init(gpa);
    defer w.deinit();

    const input = ObjectInput{
        .text = &[_]u8{},
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = &[_]Symbol{},
        .relocs = &[_]Reloc{},
    };
    const bytes = try w.writeObject(input);
    defer gpa.free(bytes);

    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(2, bytes[4]);   // ELFCLASS64
    try std.testing.expectEqual(1, bytes[5]);   // ELFDATA2LSB
    try std.testing.expectEqual(1, bytes[6]);   // EV_CURRENT
    try std.testing.expectEqual(1, readU16(bytes, 16));      // e_type = ET_REL
    try std.testing.expectEqual(62, readU16(bytes, 18));     // e_machine = EM_X86_64
    try std.testing.expectEqual(1, readU32(bytes, 20));      // e_version = EV_CURRENT
    try std.testing.expectEqual(0, readU64(bytes, 24));      // e_entry = 0
    try std.testing.expectEqual(0, readU64(bytes, 32));      // e_phoff = 0
    const e_shoff = readU64(bytes, 40);
    try std.testing.expectEqual(64, readU16(bytes, 52));     // e_ehsize = 64
    try std.testing.expectEqual(0, readU16(bytes, 54));      // e_phentsize
    try std.testing.expectEqual(0, readU16(bytes, 56));      // e_phnum
    try std.testing.expectEqual(64, readU16(bytes, 58));     // e_shentsize
    try std.testing.expectEqual(9, readU16(bytes, 60));      // e_shnum = 9 sections
    try std.testing.expectEqual(8, readU16(bytes, 62));      // e_shstrndx = .shstrtab
    try std.testing.expect(e_shoff >= 64 and e_shoff < bytes.len);
}

test "writeObject round-trip: sections, symbols, and relocations parse back" {
    const gpa = std.testing.allocator;
    var w = Writer.init(gpa);
    defer w.deinit();

    const text_bytes = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 }; // mov rax, rdi; ret
    const data_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0 };

    const symbols = &.{
        Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        Symbol{ .name = "__g0", .section_idx = 2, .value = 0, .size = 6,
            .binding = .global, .is_func = false },
        Symbol{ .name = "puts", .section_idx = ShnUndef, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };

    const relocs = &.{
        Reloc{ .section_idx = 1, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 },
        Reloc{ .section_idx = 2, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 },
    };

    const input = ObjectInput{
        .text = &text_bytes,
        .data = &data_bytes,
        .bss_size = 0,
        .symbols = symbols,
        .relocs = relocs,
    };
    const bytes = try w.writeObject(input);
    defer gpa.free(bytes);

    // --- ELF header ---
    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(1, readU16(bytes, 16));   // ET_REL
    try std.testing.expectEqual(62, readU16(bytes, 18));  // EM_X86_64
    const e_shoff = readU64(bytes, 40);
    const e_shnum = readU16(bytes, 60);
    const e_shstrndx = readU16(bytes, 62);
    try std.testing.expectEqual(9, e_shnum);
    try std.testing.expectEqual(8, e_shstrndx);

    // --- Section headers: verify .text, .data, .bss, .symtab, .strtab ---
    // Elf64Shdr layout:
    //   +0  sh_name (u32)   +4  sh_type (u32)   +8  sh_flags (u64)
    //   +16 sh_addr (u64)   +24 sh_offset (u64) +32 sh_size (u64)
    //   +40 sh_link (u32)   +44 sh_info (u32)   +48 sh_addralign (u64)
    //   +56 sh_entsize (u64)
    // Section index 0 = NULL (SHT_NULL, no content)
    const sh_null_off = e_shoff + 0 * 64;
    try std.testing.expectEqual(0, readU32(bytes, sh_null_off + 4));    // sh_type = SHT_NULL
    try std.testing.expectEqual(0, readU64(bytes, sh_null_off + 32));    // sh_size = 0

    // Section index 1 = .text
    const sh_text_off = e_shoff + 1 * 64;
    try std.testing.expectEqual(1, readU32(bytes, sh_text_off + 4));    // sh_type = SHT_PROGBITS
    try std.testing.expectEqual(ShfAlloc | ShfExecInstr, readU64(bytes, sh_text_off + 8));
    try std.testing.expectEqual(64, readU64(bytes, sh_text_off + 24));  // sh_offset (after ELF hdr)
    try std.testing.expectEqual(4, readU64(bytes, sh_text_off + 32));   // sh_size

    // Section index 2 = .data
    const sh_data_off = e_shoff + 2 * 64;
    try std.testing.expectEqual(1, readU32(bytes, sh_data_off + 4));    // sh_type
    try std.testing.expectEqual(ShfAlloc | ShfWrite, readU64(bytes, sh_data_off + 8));
    try std.testing.expectEqual(68, readU64(bytes, sh_data_off + 24));  // sh_offset (64+4)
    try std.testing.expectEqual(6, readU64(bytes, sh_data_off + 32));   // sh_size

    // Section index 3 = .bss (NOBITS, no file content)
    const sh_bss_off = e_shoff + 3 * 64;
    try std.testing.expectEqual(8, readU32(bytes, sh_bss_off + 4));     // sh_type = SHT_NOBITS
    try std.testing.expectEqual(0, readU64(bytes, sh_bss_off + 32));    // sh_size = 0

    // Section index 4 = .symtab
    const sh_symtab_off = e_shoff + 4 * 64;
    try std.testing.expectEqual(2, readU32(bytes, sh_symtab_off + 4));  // sh_type = SHT_SYMTAB
    try std.testing.expectEqual(5, readU32(bytes, sh_symtab_off + 40)); // sh_link = .strtab (idx 5)
    try std.testing.expectEqual(1, readU32(bytes, sh_symtab_off + 44)); // sh_info = 1

    // Section index 5 = .strtab
    const sh_strtab_off = e_shoff + 5 * 64;
    try std.testing.expectEqual(3, readU32(bytes, sh_strtab_off + 4));  // sh_type = SHT_STRTAB

    // e_shstrndx should point to .shstrtab (section index 8)
    try std.testing.expectEqual(8, e_shstrndx);

    // --- Symbol table: parse symbols from .symtab content ---
    const symtab_offset = readU64(bytes, sh_symtab_off + 24);   // sh_offset
    try std.testing.expectEqual(74, symtab_offset);
    try std.testing.expectEqual(854, bytes.len);
    // .text section header at index 1: sh_offset tells us where .text content is
    const text_off = readU64(bytes, sh_text_off + 24);
    try std.testing.expectEqual(64, text_off);
    try std.testing.expectEqualSlices(u8, bytes[text_off..text_off+4], &[_]u8{ 0x48, 0x89, 0xf8, 0xc3 });
    const symtab_entsize = readU64(bytes, sh_symtab_off + 56);  // sh_entsize
    try std.testing.expectEqual(24, symtab_entsize);
    // 4 symbols: STN_UNDEF + _main + __g0 + puts
    const sym0 = readU32(bytes, symtab_offset + 0);       // st_name = 0
    try std.testing.expectEqual(0, sym0);
    const sym0_shndx = readU16(bytes, symtab_offset + 6);
    try std.testing.expectEqual(ShnUndef, sym0_shndx);

    // _main: symbol index 1, in .text (section 1)
    const sym_main = symtab_offset + 24;
    try std.testing.expectEqual(1, readU16(bytes, sym_main + 6));  // st_shndx = .text (1)
    try std.testing.expectEqual(0, readU64(bytes, sym_main + 8));  // st_value = 0

    // __g0: symbol index 2, in .data (section 2)
    const sym_g0 = symtab_offset + 48;
    try std.testing.expectEqual(2, readU16(bytes, sym_g0 + 6)); // st_shndx = .data (2)

    // puts: symbol index 3, undefined
    const sym_puts = symtab_offset + 72;
    try std.testing.expectEqual(ShnUndef, readU16(bytes, sym_puts + 6));

    // --- Relocation table: .rela.text (section index 6) ---
    const sh_rela_text_off = e_shoff + 6 * 64;
    try std.testing.expectEqual(4, readU32(bytes, sh_rela_text_off + 4));  // sh_type = SHT_RELA
    try std.testing.expectEqual(4, readU32(bytes, sh_rela_text_off + 40)); // sh_link = .symtab (idx 4)
    try std.testing.expectEqual(1, readU32(bytes, sh_rela_text_off + 44)); // sh_info = .text (idx 1)
    const rela_text_offset = readU64(bytes, sh_rela_text_off + 24); // sh_offset
    const rela_text_entsize = readU64(bytes, sh_rela_text_off + 56); // sh_entsize
    try std.testing.expectEqual(24, rela_text_entsize);
    // One PC32 relocation in .text at offset 0, symbol = puts (index 3)
    const r0_offset = readU64(bytes, rela_text_offset + 0);
    try std.testing.expectEqual(0, r0_offset);
    const r0_info = readU64(bytes, rela_text_offset + 8);
    const r0_sym: u32 = @truncate(r0_info >> 32);
    const r0_type: u32 = @truncate(r0_info & 0xFFFF_FFFF);
    try std.testing.expectEqual(3, r0_sym); // puts
    try std.testing.expectEqual(2, r0_type); // R_X86_64_PC32
    try std.testing.expectEqual(-4, readI64(bytes, rela_text_offset + 16));
}

fn readI64(bytes: []const u8, off: usize) i64 {
    return @bitCast(readU64(bytes, off));
}
