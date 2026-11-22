//! Ferro PE/COFF executable writer (Windows).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const MergedImage = ferro_types.MergedImage;
const Subsystem = ferro_types.Subsystem;

// ============================================================================
// PE/COFF executable writer (Windows)
// ============================================================================

const PeMagic: u16 = 0x20b; // PE32+
const PeSubsystemConsole: u16 = 3;
const PeSubsystemGui: u16 = 2;
const PeCharacteristicsExecImage: u16 = 0x0002;
const PeCharacteristicsRelocsStripped: u16 = 0x0001;
const PeCharacteristicsLargeAddressAware: u16 = 0x0020;
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

/// The Windows entry point that Ferro synthesizes to call `_main` and return
/// to the Windows loader:
///
///     call _main      ; rel32 against _main's merged address
///     ret             ; return to the Windows loader (process terminates)
///
/// Using `call`+`ret` preserves the Windows return address chain: the loader
/// places Windows' return address at [RSP] at process entry; `call _main`
/// pushes the stub's return address below it; `_main`'s `ret` pops the stub's
/// address; the stub's `ret` pops Windows' address, returning to the loader.
///
/// After `call _main`, RSP ≡ 0 mod 16 at `_main` entry. After `push rbp`,
/// RSP ≡ 8 mod 16. `sub rsp, frame_size` with frame_size ≡ 8 mod 16 restores
/// RSP ≡ 0 mod 16 for CALL alignment inside _main.
///
/// All displacements are computed against the stub's own address, so no
/// external shim assembly or relocation table is needed. The image base
/// cancels because every address is relative to the same image base.
fn buildWindowsMainStub(
    gpa: Allocator,
    main_rel_addr: u64,
    stub_rel_addr: u64,
) ![]u8 {
    // Must stay in sync with `ferro_types.pe_entry_stub_size`, which the
    // relocation model uses to compute .data's virtual address.
    const stub_size: usize = @intCast(ferro_types.pe_entry_stub_size);
    var stub = try gpa.alloc(u8, stub_size);
    // call _main (E8 = call rel32)
    stub[0] = 0xe8;
    const call_off = stub_rel_addr; // address of the E8 byte
    const disp = @as(i64, @bitCast(main_rel_addr)) - @as(i64, @bitCast(call_off)) - 5;
    if (disp < @as(i64, std.math.minInt(i32)) or disp > @as(i64, std.math.maxInt(i32))) {
        return error.RelocationFailed;
    }
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

pub fn writeExecutablePe(
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
    // Symbol addresses in `image.symbols` are merged-text-relative (0-based
    // within merged .text). Convert to VA-relative by adding the .text section
    // base so the synthesized entry stub's call displacements land on the
    // right symbols.
    const main_addr_va = text_sec_vaddr + entry_symbol_addr;
    const stub = try buildWindowsMainStub(gpa, main_addr_va, stub_rel_addr);
    defer gpa.free(stub);

    const full_text_size = text_size + stub.len;

    // TLS has a file-backed initialization template and an optional zero-fill
    // tail. The 40-byte IMAGE_TLS_DIRECTORY64 lives at the end of .data.
    const emit_tls = image.tls.len > 0 or image.tls_zero_fill_size > 0;
    const tls_directory_size: u64 = if (emit_tls) 40 else 0;
    const full_data_size = data_size + tls_directory_size;

    // Zero-size sections would place their VA at/above SizeOfImage, which the
    // Windows loader rejects. Emit only sections that have actual content.
    const emit_bss = image.bss_size > 0;
    const sec_count: u16 = 2 + @as(u16, if (emit_tls) 1 else 0) + @as(u16, if (emit_bss) 1 else 0);

    const headers_raw_size: u64 = 64 + 4 + 20 + @as(u64, PeSizeOfOptionalHeader) + @as(u64, sec_count) * 40;
    const size_of_headers = alignUp(headers_raw_size, PeFileAlign);

    // SizeOfRawData must be a multiple of FileAlignment (PE spec).
    const text_raw_size = alignUp(full_text_size, PeFileAlign);
    const data_raw_size = alignUp(full_data_size, PeFileAlign);
    const tls_raw_size = if (emit_tls) alignUp(image.tls.len, PeFileAlign) else 0;

    const text_file_off = size_of_headers;
    const data_file_off = text_file_off + text_raw_size;
    const tls_file_off = data_file_off + data_raw_size;
    const total_file_size = tls_file_off + tls_raw_size;

    const text_sec_vaddr_final = text_sec_vaddr;
    const data_sec_vaddr = alignUp(text_sec_vaddr_final + full_text_size, PeSecAlign);
    const data_sec_end = alignUp(data_sec_vaddr + full_data_size, PeSecAlign);
    const tls_sec_vaddr = data_sec_end;
    const tls_sec_end = if (emit_tls) alignUp(tls_sec_vaddr + image.tls.len + image.tls_zero_fill_size, PeSecAlign) else data_sec_end;
    const bss_sec_vaddr = tls_sec_end;
    const size_of_image = if (emit_bss) alignUp(bss_sec_vaddr + image.bss_size, PeSecAlign) else tls_sec_end;

    const subsystem_val = if (subsystem == .gui) PeSubsystemGui else PeSubsystemConsole;
    // AddressOfEntryPoint is an RVA (relative to the image base), not a VA.
    const address_of_entry_point = stub_rel_addr;

    var buf = try gpa.alloc(u8, total_file_size);
    for (buf) |*b| b.* = 0;
    var pos: u64 = 0;

    buf[0] = 'M';
    buf[1] = 'Z';
    putU32At(buf, 60, 64); // e_lfanew = offset to PE signature
    pos = 64;

    // ---- PE signature "PE\0\0" ----
    buf[pos] = 'P';
    buf[pos + 1] = 'E';
    buf[pos + 2] = 0;
    buf[pos + 3] = 0;
    pos += 4;

    // ---- COFF file header (20 bytes) ----
    putU16At(buf, pos, 0x8664);
    pos += 2; // machine
    putU16At(buf, pos, sec_count);
    pos += 2;
    putU32At(buf, pos, 0);
    pos += 4; // time_date_stamp
    putU32At(buf, pos, 0);
    pos += 4; // pointer_to_symbol_table
    putU32At(buf, pos, 0);
    pos += 4; // number_of_symbols
    putU16At(buf, pos, PeSizeOfOptionalHeader);
    pos += 2;
    putU16At(buf, pos, PeCharacteristicsExecImage | PeCharacteristicsRelocsStripped | PeCharacteristicsLargeAddressAware);
    pos += 2;

    // ---- Optional header (PE32+, 240 bytes) ----
    putU16At(buf, pos, PeMagic);
    pos += 2; // magic
    pos += 2; // linker version (major/minor = 0)
    putU32At(buf, pos, @as(u32, @intCast(full_text_size)));
    pos += 4; // size_of_code
    putU32At(buf, pos, @as(u32, @intCast(full_data_size + image.tls.len)));
    pos += 4; // size_of_initialized_data
    putU32At(buf, pos, @intCast(image.bss_size));
    pos += 4; // size_of_uninitialized_data
    putU32At(buf, pos, @as(u32, @intCast(address_of_entry_point & 0xFFFF_FFFF)));
    pos += 4; // address_of_entry_point (low 32)
    putU32At(buf, pos, @as(u32, @intCast(text_sec_vaddr_final)));
    pos += 4; // base_of_code
    putU64At(buf, pos, PeImageBase);
    pos += 8; // image_base
    putU32At(buf, pos, PeSecAlign);
    pos += 4; // section_alignment
    putU32At(buf, pos, PeFileAlign);
    pos += 4; // file_alignment
    putU16At(buf, pos, 6);
    pos += 2; // os_major (Windows Vista+)
    putU16At(buf, pos, 0);
    pos += 2; // os_minor
    putU16At(buf, pos, 0);
    pos += 2; // image_major
    putU16At(buf, pos, 0);
    pos += 2; // image_minor
    putU16At(buf, pos, 6);
    pos += 2; // subsystem_major
    putU16At(buf, pos, 0);
    pos += 2; // subsystem_minor
    putU32At(buf, pos, 0);
    pos += 4; // win32_version_value = 0
    putU32At(buf, pos, @as(u32, @intCast(size_of_image)));
    pos += 4; // size_of_image
    putU32At(buf, pos, @as(u32, @intCast(size_of_headers)));
    pos += 4; // size_of_headers
    putU32At(buf, pos, 0);
    pos += 4; // checksum
    putU16At(buf, pos, subsystem_val);
    pos += 2; // subsystem
    // dll_characteristics: NX_COMPAT | TERMINAL_SERVER_AWARE. Deliberately
    // NOT DYNAMIC_BASE/HIGH_ENTROPY_VA: the image is emitted with
    // relocs-stripped and a fixed preferred base, and Ferro writes absolute
    // pointers for that base. With no .reloc section the loader could not
    // fix anything up after moving the image, so ASLR must be off.
    putU16At(buf, pos, 0x0120);
    pos += 2;
    putU64At(buf, pos, 0x1000000);
    pos += 8; // size_of_stack_reserve (16 MB, match ore.exe)
    putU64At(buf, pos, 0x1000);
    pos += 8; // size_of_stack_commit
    putU64At(buf, pos, 0x100000);
    pos += 8; // size_of_heap_reserve
    putU64At(buf, pos, 0x1000);
    pos += 8; // size_of_heap_commit
    putU32At(buf, pos, 0);
    pos += 4; // loader_flags
    putU32At(buf, pos, PeNumberOfRvaAndSizes);
    pos += 4; // number_of_rva_and_sizes
    // data directories: 16 x 8 bytes. Entry 1 = imports, entry 9 = TLS.
    const import_desc_rva: u64 = if (image.import_desc_addr > image.text.len)
        data_sec_vaddr + (image.import_desc_addr - image.text.len)
    else
        0;
    const import_desc_size: u64 = if (import_desc_rva != 0) image.import_desc_size else 0;
    const tls_directory_rva: u64 = if (emit_tls) data_sec_vaddr + data_size else 0;
    var di: u32 = 0;
    while (di < PeNumberOfRvaAndSizes) : (di += 1) {
        if (di == 1) {
            putU32At(buf, pos, @as(u32, @intCast(import_desc_rva & 0xFFFFFFFF)));
            pos += 4;
            putU32At(buf, pos, @as(u32, @intCast(import_desc_size & 0xFFFFFFFF)));
            pos += 4;
        } else if (di == 9) {
            putU32At(buf, pos, @intCast(tls_directory_rva));
            pos += 4;
            putU32At(buf, pos, if (emit_tls) 40 else 0);
            pos += 4;
        } else {
            putU32At(buf, pos, 0);
            pos += 4;
            putU32At(buf, pos, 0);
            pos += 4;
        }
    }

    // ---- Section table (sec_count x 40 bytes) ----
    var sec_names: [4][]const u8 = undefined;
    var sec_characteristics: [4]u32 = undefined;
    var sec_vaddrs: [4]u64 = undefined;
    var sec_vsizes: [4]u64 = undefined;
    var sec_file_offs: [4]u64 = undefined;
    var sec_raw_sizes: [4]u64 = undefined;
    sec_names[0] = ".text";
    sec_characteristics[0] = 0x60000020;
    sec_vaddrs[0] = text_sec_vaddr_final;
    sec_vsizes[0] = full_text_size;
    sec_file_offs[0] = text_file_off;
    sec_raw_sizes[0] = text_raw_size;
    sec_names[1] = ".data";
    sec_characteristics[1] = 0xC0000040;
    sec_vaddrs[1] = data_sec_vaddr;
    sec_vsizes[1] = full_data_size;
    sec_file_offs[1] = data_file_off;
    sec_raw_sizes[1] = data_raw_size;
    var next_sec: usize = 2;
    if (emit_tls) {
        sec_names[next_sec] = ".tls";
        sec_characteristics[next_sec] = 0xC0000040;
        sec_vaddrs[next_sec] = tls_sec_vaddr;
        sec_vsizes[next_sec] = image.tls.len + image.tls_zero_fill_size;
        sec_file_offs[next_sec] = tls_file_off;
        sec_raw_sizes[next_sec] = tls_raw_size;
        next_sec += 1;
    }
    if (emit_bss) {
        sec_names[next_sec] = ".bss";
        sec_characteristics[next_sec] = 0x80000080;
        sec_vaddrs[next_sec] = bss_sec_vaddr;
        sec_vsizes[next_sec] = image.bss_size;
        sec_file_offs[next_sec] = 0;
        sec_raw_sizes[next_sec] = 0;
    }

    var si: usize = 0;
    while (si < @as(usize, sec_count)) : (si += 1) {
        const soff = pos + @as(u64, si) * 40;
        for (0..8) |k| {
            buf[soff + @as(u64, k)] = if (k < sec_names[si].len) sec_names[si][k] else 0;
        }
        putU32At(buf, soff + 8, @as(u32, @intCast(sec_vsizes[si]))); // virtual_size
        putU32At(buf, soff + 12, @as(u32, @intCast(sec_vaddrs[si]))); // virtual_address
        putU32At(buf, soff + 16, @as(u32, @intCast(sec_raw_sizes[si]))); // size_of_raw_data
        putU32At(buf, soff + 20, if (sec_raw_sizes[si] == 0) 0 else @as(u32, @intCast(sec_file_offs[si]))); // pointer_to_raw_data
        putU32At(buf, soff + 24, 0); // pointer_to_relocations (unused)
        putU32At(buf, soff + 28, 0); // pointer_to_line_numbers
        putU16At(buf, soff + 32, 0); // number_of_relocations
        putU16At(buf, soff + 34, 0); // number_of_line_numbers
        putU32At(buf, soff + 36, sec_characteristics[si]); // characteristics
    }
    // `pos` now points just past the section table (end of headers).
    // Section raw data begins at `size_of_headers` (computed above from
    // headers_raw_size, which matches alignUp(actual_headers_end, PeFileAlign)).

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
    // ---- .tls template and IMAGE_TLS_DIRECTORY64 ----
    if (emit_tls) {
        for (image.tls, 0..image.tls.len) |b, i| {
            buf[tls_file_off + @as(u64, i)] = b;
        }
        const directory_off = data_file_off + data_size;
        putU64At(buf, directory_off + 0, PeImageBase + tls_sec_vaddr); // StartAddressOfRawData
        putU64At(buf, directory_off + 8, PeImageBase + tls_sec_vaddr + image.tls.len); // EndAddressOfRawData
        putU64At(buf, directory_off + 16, PeImageBase + data_sec_vaddr + image.tls_index_offset); // AddressOfIndex
        putU64At(buf, directory_off + 24, 0); // AddressOfCallBacks
        putU32At(buf, directory_off + 32, @intCast(image.tls_zero_fill_size)); // SizeOfZeroFill
        putU32At(buf, directory_off + 36, 0); // Characteristics
    }
    // Absolute 64-bit pointers in .data were written as merged-image
    // offsets (base 0) by the relocation applier. The image loads at
    // `PeImageBase` with .text at `PeSecAlign` and (relocs being stripped)
    // the base never moves, so add the delta the loader won't. Import IAT
    // slots are not in this list: the loader patches those itself.
    for (image.addr64_sites.items) |site| {
        const off = data_file_off + site;
        const cur = readU64(buf, @intCast(off));
        const patched = cur + PeImageBase + PeSecAlign;
        putU64At(buf, off, patched);
    }

    return buf;
}

fn readU64(buf: []const u8, pos: u64) u64 {
    var v: u64 = 0;
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        v |= @as(u64, buf[pos + @as(u64, i)]) << i * 8;
    }
    return v;
}

test "PE writer emits a writable TLS template and directory" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var symbols = std.StringHashMap(ferro_types.ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    try symbols.put("_main", .{ .section = ".text", .value = 0 });

    var text: [1]u8 = .{0xc3};
    var data: [4]u8 = @splat(0);
    var tls: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var image = MergedImage{
        .text = &text,
        .data = &data,
        .bss_size = 0,
        .tls = &tls,
        .tls_zero_fill_size = 8,
        .tls_index_offset = 0,
        .symbols = symbols,
        .import_thunks = .empty,
        .import_desc_addr = 0,
        .import_desc_size = 0,
        .abs32_sites = .empty,
        .addr64_sites = .empty,
    };
    const buf = try writeExecutablePe(&image, 0, .console, gpa);
    defer gpa.free(buf);

    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, buf[70..72], .little));
    const data_dirs = 88 + 112;
    try testing.expectEqual(@as(u32, 0x2004), std.mem.readInt(u32, buf[data_dirs + 9 * 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, buf[data_dirs + 9 * 8 + 4 ..][0..4], .little));

    const section_table = 88 + PeSizeOfOptionalHeader;
    try testing.expectEqual(@as(u32, 0xC0000040), std.mem.readInt(u32, buf[section_table + 40 + 36 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0xC0000040), std.mem.readInt(u32, buf[section_table + 80 + 36 ..][0..4], .little));

    // One 512-byte text section and one 512-byte data section precede .tls.
    const directory_off = 512 + 512 + data.len;
    try testing.expectEqual(PeImageBase + 0x3000, readU64(buf, directory_off));
    try testing.expectEqual(PeImageBase + 0x3000 + tls.len, readU64(buf, directory_off + 8));
    try testing.expectEqual(PeImageBase + 0x2000, readU64(buf, directory_off + 16));
    try testing.expectEqual(@as(u64, 0), readU64(buf, directory_off + 24));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, buf[directory_off + 32 ..][0..4], .little));
    try testing.expectEqualSlices(u8, &tls, buf[1536..1544]);
}
