//! PE/COFF object writer for x86-64 Windows.
//!
//! Writes a relocatable COFF object from sections, symbols, and relocation
//! records. Byte-level emitter for `emitObject` on the Windows target,
//! mirroring `obj_elf.zig` (ELF64 on Linux).
//!
//! Format contract is frozen in `docs/adr/adr_object_format.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro = @import("ferro.zig");

// ============================================================================
// PE/COFF constants
// ============================================================================

pub const CoffMachineAmd64: u16 = 0x8664; // IMAGE_FILE_MACHINE_AMD64

pub const CoffRelocRel32: u16 = 4;  // IMAGE_REL_AMD64_REL32
pub const CoffRelocAddr64: u16 = 1; // IMAGE_REL_AMD64_ADDR64

pub const ScnCntCode: u32 = 0x00000020;        // IMAGE_SCN_CNT_CODE
pub const ScnCntInitializedData: u32 = 0x00000040; // IMAGE_SCN_CNT_INITIALIZED_DATA
pub const ScnCntUninitializedData: u32 = 0x00000080; // IMAGE_SCN_CNT_UNINITIALIZED_DATA
pub const ScnMemExecute: u32 = 0x20000000;     // IMAGE_SCN_MEM_EXECUTE
pub const ScnMemRead: u32 = 0x40000000;        // IMAGE_SCN_MEM_READ
pub const ScnMemWrite: u32 = 0x80000000;       // IMAGE_SCN_MEM_WRITE

pub const SymClassExternal: u8 = 2; // IMAGE_SYM_CLASS_EXTERNAL
pub const SymTypeNull: u16 = 0;
pub const SymTypeFunction: u16 = 0x0020; // IMAGE_SYM_TYPE_FUNCTION

const CoffSymSize: u64 = 18;
const CoffAuxSectionSize: u64 = 18;
const CoffRelocSize: u64 = 10;

const SectionUndefined: u16 = 0; // COFF section numbers are 1-based; 0 = undefined

// Section table entry count (.text, .data, .bss)
const SectionCount: u16 = 3;

// ============================================================================
// Input model (shared with obj_elf.zig so codegen feeds both writers).
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

    sec_name_offsets: std.ArrayList(u32),
    sec_characteristics: std.ArrayList(u32),
    sec_size: std.ArrayList(u64),
    sec_reloc_count: std.ArrayList(u32),
    sec_reloc_offset: std.ArrayList(u64),

    pub fn init(gpa: Allocator) Writer {
        return .{
            .gpa = gpa, .buf = .empty, .strtab = .empty,
            .sec_name_offsets = .empty, .sec_characteristics = .empty,
            .sec_size = .empty, .sec_reloc_count = .empty, .sec_reloc_offset = .empty,
        };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.gpa);
        self.strtab.deinit(self.gpa);
        self.sec_name_offsets.deinit(self.gpa);
        self.sec_characteristics.deinit(self.gpa);
        self.sec_size.deinit(self.gpa);
        self.sec_reloc_count.deinit(self.gpa);
        self.sec_reloc_offset.deinit(self.gpa);
    }

    /// Emit a complete PE/COFF object from `input`. Returns an allocated byte
    /// slice the caller frees with `writer.gpa.free(result)`.
    pub fn writeObject(self: *Writer, input: ObjectInput) ![]u8 {
        try self.build(input);

        const text_size = @as(u64, @intCast(input.text.len));
        const data_size = @as(u64, @intCast(input.data.len));

        var num_text_relocs: u32 = 0;
        var num_data_relocs: u32 = 0;
        for (input.relocs) |r| {
            if (r.section_idx == 0) {
                num_text_relocs += 1; // .text (codegen emits 0-based section indices)
            } else if (r.section_idx == 1) {
                num_data_relocs += 1; // .data
            }
        }

        // File layout:
        //   [0, 20)       COFF file header (20 bytes)
        //   [20, 140)     section table (3 x 40 bytes)
        //   [140, ...)    .text raw data, then .data raw data (.bss: none)
        //   [...]         .text relocations (10 bytes each), then .data relocations
        //   [...]         symbol table
        //   [...]         string table

        const headers_size: u64 = 20 + 40 * @as(u64, @intCast(SectionCount));
        const section_data_start = headers_size;
        const text_file_off = section_data_start;
        const data_file_off = text_file_off + text_size;
        const text_reloc_off = data_file_off + data_size;
        const data_reloc_off = text_reloc_off + 10 * @as(u64, num_text_relocs);
        const symtab_file_off = data_reloc_off + 10 * @as(u64, num_data_relocs);

        // Symbol table layout:
        //   index 0: null symbol
        //   section symbols: .text(1), .data(2), .bss(3), each + 1 aux
        //   input symbols: each 1 entry (+ 1 aux if defined)
        var sym_count: u64 = 1;
        sym_count += SectionCount * 2; // 3 sections x (sym + aux)
        for (input.symbols) |sym| {
            sym_count += 1;
            if (sym.section_idx != SectionUndefined) sym_count += 1;
        }
        const symtab_size = sym_count * CoffSymSize;

        // String table: size dword (4 bytes) + name bytes for names > 8 chars.
        var strtab_size: u64 = 4;
        for (input.symbols) |sym| {
            if (sym.name.len > 8) strtab_size += @as(u64, sym.name.len) + 1;
        }

        const total_size = symtab_file_off + symtab_size + strtab_size;
        var final_buf: []u8 = try self.gpa.alloc(u8, total_size);
        var pos: u64 = 0;

        // --- COFF file header (20 bytes) ---
        try putU16(final_buf, &pos, CoffMachineAmd64);       // machine
        try putU16(final_buf, &pos, SectionCount);           // number_of_sections
        try putU32(final_buf, &pos, 0);                      // time_date_stamp
        try putU32(final_buf, &pos, @intCast(symtab_file_off)); // pointer_to_symbol_table
        try putU32(final_buf, &pos, @intCast(sym_count));    // number_of_symbols
        try putU16(final_buf, &pos, 0);                      // size_of_optional_header
        try putU16(final_buf, &pos, 0x0001);                 // characteristics (RELOCS_STRIPPED)

        // --- Section table (3 x 40 bytes) ---
        const sec_names = [_][]const u8{ ".text", ".data", ".bss" };
        const sec_characteristics = [_]u32{
            ScnCntCode | ScnMemExecute | ScnMemRead,
            ScnCntInitializedData | ScnMemRead | ScnMemWrite,
            ScnCntUninitializedData | ScnMemRead | ScnMemWrite,
        };
        const sec_sizes = [_]u64{ text_size, data_size, input.bss_size };
        const sec_file_offs = [_]u64{ text_file_off, data_file_off, 0 };
        const sec_reloc_offs = [_]u64{ text_reloc_off, data_reloc_off, 0 };
        const sec_reloc_counts = [_]u32{ num_text_relocs, num_data_relocs, 0 };

        var si: usize = 0;
        while (si < SectionCount) : (si += 1) {
            const name = sec_names[si];
            // 8-byte name field (null-padded).
            for (0..8) |k| {
                try putU8(final_buf, &pos, if (k < name.len) name[k] else 0);
            }
            try putU32(final_buf, &pos, @intCast(sec_sizes[si]));            // virtual_size
            try putU32(final_buf, &pos, @intCast(if (sec_file_offs[si] == 0) 0 else sec_file_offs[si] - section_data_start)); // virtual_address
            try putU32(final_buf, &pos, @intCast(sec_sizes[si]));            // size_of_raw_data
            try putU32(final_buf, &pos, if (sec_sizes[si] == 0) 0 else @intCast(sec_file_offs[si])); // pointer_to_raw_data
            try putU32(final_buf, &pos, if (sec_reloc_counts[si] == 0) 0 else @intCast(sec_reloc_offs[si])); // pointer_to_relocations
            try putU32(final_buf, &pos, 0);                                  // pointer_to_line_numbers
            try putU16(final_buf, &pos, @intCast(sec_reloc_counts[si]));     // number_of_relocations
            try putU16(final_buf, &pos, 0);                                  // number_of_line_numbers
            try putU32(final_buf, &pos, sec_characteristics[si]);            // characteristics
        }

        // --- Section raw data (.text, .data) ---
        {
            var dst = text_file_off;
            for (input.text) |b| { final_buf[dst] = b; dst += 1; }
        }
        {
            var dst = data_file_off;
            for (input.data) |b| { final_buf[dst] = b; dst += 1; }
        }

        // --- Relocation tables (.text then .data) ---
        // Build symbol name -> index map first (symbol table emitted next).
        var sym_index_map = std.StringHashMap(u32).init(self.gpa);
        defer sym_index_map.deinit();

        // --- Symbol table ---
        pos = symtab_file_off;

        // index 0: null symbol (all zero bytes).
        for (0..CoffSymSize) |_| {
            try putU8(final_buf, &pos, 0);
        }
        _ = try sym_index_map.put("", 0);

        // Section symbols (.text, .data, .bss), each + 1 aux.
        var section_number: u16 = 1;
        si = 0;
        while (si < SectionCount) : (si += 1) {
            const name = sec_names[si];
            var sym_name: [8]u8 = undefined;
            for (0..8) |k| { sym_name[k] = if (k < name.len) name[k] else 0; }
            // symbol entry: name(8) + value(4) + section_number(2) + type(2) + storage_class(1) + aux_count(1)
            for (0..8) |k| { try putU8(final_buf, &pos, sym_name[k]); }
            try putU32(final_buf, &pos, 0);                                   // value
            try putI16(final_buf, &pos, @intCast(section_number));            // section_number
            try putU16(final_buf, &pos, SymTypeNull);                         // type
            try putU8(final_buf, &pos, SymClassExternal);                     // storage_class
            try putU8(final_buf, &pos, 1);                                    // number_of_aux_symbols
            _ = try sym_index_map.put(name, @as(u32, @intCast(section_number)));    // symbol index = section_number
            section_number += 1;

            // aux section record.
            try putU32(final_buf, &pos, @intCast(sec_sizes[si]));             // size
            try putU16(final_buf, &pos, @intCast(sec_reloc_counts[si]));      // number_of_relocations
            try putU16(final_buf, &pos, 0);                                   // number_of_line_numbers
            try putU32(final_buf, &pos, 0);                                   // checksum
            try putU16(final_buf, &pos, 0);                                   // number
            try putU8(final_buf, &pos, 0);                                    // selection
            try putU8(final_buf, &pos, 0);                                    // pad0
            try putU8(final_buf, &pos, 0);                                    // pad1
            try putU8(final_buf, &pos, 0);                                    // pad2
        }

        // Input symbols.
        for (input.symbols) |sym| {
            const sym_index = @as(u32, @intCast((pos - symtab_file_off) / CoffSymSize));
            _ = try sym_index_map.put(sym.name, sym_index);

            var sym_name: [8]u8 = undefined;
            var use_strtab = false;
            var strtab_name_off: u64 = 0;
            if (sym.name.len <= 8) {
                for (0..8) |k| { sym_name[k] = if (k < sym.name.len) sym.name[k] else 0; }
            } else {
                use_strtab = true;
                strtab_name_off = strtab_size - 4; // offset within string table (after size dword)
                // first 4 bytes of name field = offset with high bit set; next 4 = 0.
                for (0..4) |k| { sym_name[k] = @as(u8, @truncate((strtab_name_off >> @intCast(k * 8)) & 0xFF)); }
                sym_name[0] = @as(u8, sym_name[0] | 0x80);
                for (4..8) |k| { sym_name[k] = 0; }
                strtab_size += @as(u64, sym.name.len) + 1;
            }

            const sec_num = if (sym.section_idx == SectionUndefined) SectionUndefined else sym.section_idx;
            const sym_type = if (sym.is_func) SymTypeFunction else SymTypeNull;
            const defined = sym.section_idx != SectionUndefined;
            const aux_count: u8 = if (defined) 1 else 0;

            for (0..8) |k| { try putU8(final_buf, &pos, sym_name[k]); }
            try putU32(final_buf, &pos, @intCast(sym.value));                  // value
            try putI16(final_buf, &pos, @intCast(sec_num));                    // section_number
            try putU16(final_buf, &pos, sym_type);                             // type
            try putU8(final_buf, &pos, SymClassExternal);                      // storage_class
            try putU8(final_buf, &pos, aux_count);                             // number_of_aux_symbols

            if (defined) {
                // aux symbol record.
                try putU32(final_buf, &pos, @intCast(sym.size));               // size
                try putU16(final_buf, &pos, 0);                                // number_of_relocations
                try putU16(final_buf, &pos, 0);                                // number_of_line_numbers
                try putU32(final_buf, &pos, 0);                                // checksum
                try putU16(final_buf, &pos, 0);                                // number
                try putU8(final_buf, &pos, 0);                                 // selection
                try putU8(final_buf, &pos, 0);                                 // pad0
                try putU8(final_buf, &pos, 0);                                 // pad1
                try putU8(final_buf, &pos, 0);                                 // pad2
            }
        }

        // --- String table ---
        pos = symtab_file_off + symtab_size;
        // size dword (4 bytes).
        const strtab_start = pos;
        try putU32(final_buf, &pos, 0); // placeholder, patched below
        // write long names (>8 bytes).
        for (input.symbols) |sym| {
            if (sym.name.len > 8) {
                for (sym.name) |b| { try putU8(final_buf, &pos, b); }
                try putU8(final_buf, &pos, 0);
            }
        }
        // patch string table size.
        const total_str_size: u32 = @intCast(pos - strtab_start);
        for (0..4) |i| {
            final_buf[strtab_start + @as(u64, i)] = @truncate((total_str_size >> @intCast(i * 8)) & 0xFF);
        }

        // --- Relocations (patch into place) ---
        var text_reloc_cursor = text_reloc_off;
        var data_reloc_cursor = data_reloc_off;
        for (input.relocs) |r| {
            const sym_index = sym_index_map.get(r.symbol).?;
            const r_type = switch (r.kind) {
                .pc32 => CoffRelocRel32,
                .addr64 => CoffRelocAddr64,
            };
            // For PE/COFF, addend is implicit at the site; r.addend is ignored.
            var reloc_cursor = if (r.section_idx == 0) text_reloc_cursor else data_reloc_cursor;
            try putU32(final_buf, &reloc_cursor, @as(u32, @intCast(r.offset)));   // virtual_address
            try putU32(final_buf, &reloc_cursor, sym_index);             // symbol_table_index
            try putU16(final_buf, &reloc_cursor, r_type);                // type
            if (r.section_idx == 0) {
                text_reloc_cursor += CoffRelocSize;
            } else {
                data_reloc_cursor += CoffRelocSize;
            }
        }

        return final_buf;
    }

    fn build(self: *Writer, input: ObjectInput) !void {
        try self.strtab.append(self.gpa, 0); // index 0 = NUL

        const sec_names = [_][]const u8{ ".text", ".data", ".bss" };
        for (sec_names) |name| {
            const off: u32 = @as(u32, @intCast(self.strtab.items.len));
            try self.sec_name_offsets.append(self.gpa, off);
            try self.strtab.appendSlice(self.gpa, name);
            try self.strtab.append(self.gpa, 0);
        }

        try self.sec_characteristics.append(self.gpa, ScnCntCode | ScnMemExecute | ScnMemRead);
        try self.sec_size.append(self.gpa, @as(u64, @intCast(input.text.len)));
        try self.sec_reloc_count.append(self.gpa, 0);
        try self.sec_reloc_offset.append(self.gpa, 0);

        try self.sec_characteristics.append(self.gpa, ScnCntInitializedData | ScnMemRead | ScnMemWrite);
        try self.sec_size.append(self.gpa, @as(u64, @intCast(input.data.len)));
        try self.sec_reloc_count.append(self.gpa, 0);
        try self.sec_reloc_offset.append(self.gpa, 0);

        try self.sec_characteristics.append(self.gpa, ScnCntUninitializedData | ScnMemRead | ScnMemWrite);
        try self.sec_size.append(self.gpa, input.bss_size);
        try self.sec_reloc_count.append(self.gpa, 0);
        try self.sec_reloc_offset.append(self.gpa, 0);
    }

    // ---- little-endian primitive writers ----

    fn putU8(buf: []u8, pos: *u64, v: u8) !void {
        buf[pos.*] = v;
        pos.* += 1;
    }

    fn putU16(buf: []u8, pos: *u64, v: u16) !void {
        buf[pos.*] = @truncate(v);
        buf[pos.* + 1] = @truncate(v >> 8);
        pos.* += 2;
    }

    fn putI16(buf: []u8, pos: *u64, v: i16) !void {
        try putU16(buf, pos, @bitCast(v));
    }

    fn putU32(buf: []u8, pos: *u64, v: u32) !void {
        buf[pos.*] = @truncate(v);
        buf[pos.* + 1] = @truncate(v >> 8);
        buf[pos.* + 2] = @truncate(v >> 16);
        buf[pos.* + 3] = @truncate(v >> 24);
        pos.* += 4;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "writeObject produces a valid minimal PE/COFF object header" {
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

    // COFF file header:
    //   +0  machine (u16) = 0x8664 (AMD64)
    //   +2  number_of_sections (u16) = 3
    //   +4  time_date_stamp (u32) = 0
    //   +8  pointer_to_symbol_table (u32)
    //   +12 number_of_symbols (u32)
    //   +16 size_of_optional_header (u16) = 0
    //   +18 characteristics (u16) = 0x0001
    try std.testing.expectEqual(0x8664, readU16(bytes, 0));
    try std.testing.expectEqual(3, readU16(bytes, 2));
    try std.testing.expectEqual(0, readU32(bytes, 4));
    try std.testing.expectEqual(0, readU16(bytes, 16)); // size_of_optional_header
    try std.testing.expectEqual(0x0001, readU16(bytes, 18)); // characteristics
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

fn readI64(bytes: []const u8, off: usize) i64 {
    return @bitCast(readU64(bytes, off));
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
        Symbol{ .name = "puts", .section_idx = SectionUndefined, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };

    const relocs = &.{
        Reloc{ .section_idx = 0, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 }, // .text
        Reloc{ .section_idx = 1, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 }, // .data
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

    // --- COFF file header ---
    try std.testing.expectEqual(0x8664, readU16(bytes, 0)); // machine = AMD64
    try std.testing.expectEqual(3, readU16(bytes, 2)); // 3 sections
    try std.testing.expectEqual(0, readU16(bytes, 16)); // size_of_optional_header = 0
    const ptr_to_symtab = readU32(bytes, 8);
    const num_symbols = readU32(bytes, 12);

    // --- Section table (.text, .data, .bss; 40 bytes each, starting at 20) ---
    const sh_text_off = 20 + 0 * 40;
    try std.testing.expectEqual(ScnCntCode | ScnMemExecute | ScnMemRead, readU32(bytes, sh_text_off + 36));
    try std.testing.expectEqual(4, readU32(bytes, sh_text_off + 16)); // size_of_raw_data
    try std.testing.expectEqual(20 + 40 * 3, readU32(bytes, sh_text_off + 20)); // pointer_to_raw_data

    const sh_data_off = 20 + 1 * 40;
    try std.testing.expectEqual(ScnCntInitializedData | ScnMemRead | ScnMemWrite, readU32(bytes, sh_data_off + 36));
    try std.testing.expectEqual(6, readU32(bytes, sh_data_off + 16));

    const sh_bss_off = 20 + 2 * 40;
    try std.testing.expectEqual(ScnCntUninitializedData | ScnMemRead | ScnMemWrite, readU32(bytes, sh_bss_off + 36));
    try std.testing.expectEqual(0, readU32(bytes, sh_bss_off + 16)); // size_of_raw_data = 0

    // --- Section raw data ---
    const text_off = readU32(bytes, sh_text_off + 20);
    try std.testing.expectEqual(20 + 40 * 3, text_off);
    try std.testing.expectEqualSlices(u8, bytes[text_off..text_off + 4], &[_]u8{ 0x48, 0x89, 0xf8, 0xc3 });

    // --- Symbol table ---
    // Layout: null(0), .text sym(1)+aux(2), .data sym(3)+aux(4), .bss sym(5)+aux(6),
    // then _main(7)+aux(8), __g0(9)+aux(10), puts(11). Total = 12 symbols.
    try std.testing.expectEqual(12, num_symbols);

    const _main_off = ptr_to_symtab + 7 * 18; // index 7
    try std.testing.expectEqual(1, readU16(bytes, _main_off + 12)); // section_number = .text (1)
    try std.testing.expectEqual(0, readU32(bytes, _main_off + 8)); // st_value = 0

    const __g0_off = ptr_to_symtab + 9 * 18; // index 9
    try std.testing.expectEqual(2, readU16(bytes, __g0_off + 12)); // section_number = .data (2)

    const puts_off = ptr_to_symtab + 11 * 18; // index 11
    try std.testing.expectEqual(SectionUndefined, readU16(bytes, puts_off + 12)); // undefined

    // --- Relocation table ---
    // .text relocations follow .data section data.
    const text_size = 4;
    const data_size = 6;
    const reloc_start = 20 + 40 * 3 + text_size + data_size; // after headers + section data
    // One PC32 relocation in .text at offset 0, symbol = puts (index 11)
    const r0_off = reloc_start;
    try std.testing.expectEqual(0, readU32(bytes, r0_off + 0)); // virtual_address = 0
    try std.testing.expectEqual(11, readU32(bytes, r0_off + 4)); // symbol_table_index = puts (11)
    try std.testing.expectEqual(4, readU16(bytes, r0_off + 8)); // type = IMAGE_REL_AMD64_REL32 (4)
    // One ADDR64 relocation in .data at offset 0, symbol = __g0 (index 9)
    const r1_off = reloc_start + 10;
    try std.testing.expectEqual(0, readU32(bytes, r1_off + 0));
    try std.testing.expectEqual(9, readU32(bytes, r1_off + 4));
    try std.testing.expectEqual(1, readU16(bytes, r1_off + 8)); // type = IMAGE_REL_AMD64_ADDR64 (1)
}
