//! Ferro ELF64 executable writer (Linux).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const MergedImage = ferro_types.MergedImage;
const ferro_reader = @import("ferro_reader.zig");
const readU32 = ferro_reader.readU32;
const readU64 = ferro_reader.readU64;

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
const PtTls: u32 = 7;
const PfR: u32 = 0x4;
const PfW: u32 = 0x2;
const PfX: u32 = 0x1;

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
pub fn buildLinuxStartStub(gpa: Allocator, main_addr: u64, stub_addr: u64) ![]u8 {
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

/// TLS-aware `_start`: initialize the thread pointer from this executable's
/// program headers before any runtime or program code can access TLS.
fn buildLinuxTlsStartStub(
    gpa: Allocator,
    main_addr: u64,
    init_tls_addr: u64,
    stub_addr: u64,
    phdr_vaddr: u64,
    phdr_count: u16,
) ![]u8 {
    // movabs rdi, phdr_vaddr; mov esi, phdr_count; call init; call main; exit.
    var stub = try gpa.alloc(u8, 34);
    stub[0] = 0x48;
    stub[1] = 0xbf;
    const phdr_bytes = std.mem.asBytes(&phdr_vaddr);
    for (0..8) |i| stub[2 + i] = phdr_bytes[i];
    stub[10] = 0xbe;
    const count_bytes = std.mem.asBytes(&phdr_count);
    stub[11] = count_bytes[0];
    stub[12] = count_bytes[1];
    stub[13] = 0;
    stub[14] = 0;

    stub[15] = 0xe8;
    const init_disp: i64 = @as(i64, @bitCast(init_tls_addr)) - @as(i64, @bitCast(stub_addr + 15)) - 5;
    const init_disp_i32: i32 = @intCast(init_disp);
    const init_disp_bytes = std.mem.asBytes(&init_disp_i32);
    for (0..4) |i| stub[16 + i] = init_disp_bytes[i];

    stub[20] = 0xe8;
    const main_disp: i64 = @as(i64, @bitCast(main_addr)) - @as(i64, @bitCast(stub_addr + 20)) - 5;
    const main_disp_i32: i32 = @intCast(main_disp);
    const main_disp_bytes = std.mem.asBytes(&main_disp_i32);
    for (0..4) |i| stub[21 + i] = main_disp_bytes[i];

    stub[25] = 0x89;
    stub[26] = 0xc7;
    stub[27] = 0xb8;
    stub[28] = 0x3c;
    stub[29] = 0;
    stub[30] = 0;
    stub[31] = 0;
    stub[32] = 0x0f;
    stub[33] = 0x05;
    return stub;
}

/// Write an ELF executable (ET_EXEC) whose entry `_start` calls `_main`.
///
/// Layout: ELF header (64) + 2x PT_LOAD program headers (.text R/X, .data R/W)
/// + .text content (with `_start` appended) + .data content.
///
/// `entry_symbol_addr` is the merged-image address of `_main` (from
/// `MergedImage.symbols`); `_start` is placed at the end of merged `.text`.
pub fn writeExecutableElf(
    image: *MergedImage,
    entry_symbol_addr: u64,
    gpa: Allocator,
) ![]u8 {
    const text = image.text;
    const data = image.data;
    const text_size = @as(u64, @intCast(text.len));
    const data_size = @as(u64, @intCast(data.len));

    // `_start` lives at the end of merged `.text`. TLS-aware images get two
    // extra headers (a PT_LOAD for the template and PT_TLS itself) and call
    // the runtime initializer before `_main`.
    const emit_tls = image.tls.len > 0 or image.tls_zero_fill_size > 0;
    const ehdr_size: u64 = 64;
    const phdr_count: u64 = if (emit_tls) 4 else 2;
    const phdr_size: u64 = 56 * phdr_count;
    const header_size: u64 = ehdr_size + phdr_size;
    const image_base: u64 = 0x400000;
    const text_vaddr: u64 = image_base + header_size;
    const start_offset = text_size;
    const stub = if (emit_tls) blk: {
        const init_tls = image.symbols.get("wfr_std_init_tls") orelse return error.UndefinedSymbol;
        break :blk try buildLinuxTlsStartStub(
            gpa,
            entry_symbol_addr,
            init_tls.value,
            start_offset,
            image_base + ehdr_size,
            @intCast(phdr_count),
        );
    } else try buildLinuxStartStub(gpa, entry_symbol_addr, start_offset);
    defer gpa.free(stub);

    const full_text_size = text_size + stub.len;
    var full_text = try gpa.alloc(u8, full_text_size);
    defer gpa.free(full_text);
    for (text, 0..text.len) |b, i| full_text[i] = b;
    for (stub, 0..stub.len) |b, i| full_text[text_size + i] = b;

    const text_file_off = header_size;
    const unaligned_data_file_off = text_file_off + full_text_size;
    const data_file_off = (unaligned_data_file_off + 0xFFF) & ~@as(u64, 0xFFF);
    const data_vaddr = image_base + data_file_off;
    const tls_file_off = if (emit_tls) (data_file_off + data_size + 0xFFF) & ~@as(u64, 0xFFF) else data_file_off + data_size;
    const tls_vaddr = image_base + tls_file_off;
    const total_size = tls_file_off + image.tls.len;

    var buf = try gpa.alloc(u8, total_size);
    @memset(buf, 0);
    var pos: u64 = 0;

    // ---- ELF header ----
    const ehdr = Elf64EhdrExec{
        .e_ident = .{},
        .e_type = EtExec,
        .e_machine = 62, // EM_X86_64
        .e_version = 1,
        .e_entry = text_vaddr + start_offset,
        .e_phoff = ehdr_size,
        .e_shoff = 0, // no section headers
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
            // TLS startup reads the program headers at image_base + 64, so
            // this segment must include them rather than starting at .text.
            .p_offset = if (emit_tls) 0 else text_file_off,
            .p_vaddr = if (emit_tls) image_base else text_vaddr,
            .p_paddr = if (emit_tls) image_base else text_vaddr,
            .p_filesz = if (emit_tls) text_file_off + full_text_size else full_text_size,
            .p_memsz = if (emit_tls) text_file_off + full_text_size else full_text_size,
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
    if (emit_tls) {
        // The initialization template is mapped read-only; prepareArea copies
        // it into each thread's writable TLS block.
        const tls_load = Elf64Phdr{
            .p_type = PtLoad,
            .p_flags = PfR,
            .p_offset = tls_file_off,
            .p_vaddr = tls_vaddr,
            .p_paddr = tls_vaddr,
            .p_filesz = image.tls.len,
            // Only the initialized template is mapped. The zero-fill tail is
            // per-thread state described by PT_TLS below, not read-only file
            // storage that the kernel must clear during exec.
            .p_memsz = image.tls.len,
            .p_align = 0x1000,
        };
        const tls_load_bytes = std.mem.asBytes(&tls_load);
        for (0..tls_load_bytes.len) |i| buf[pos + @as(u64, i)] = tls_load_bytes[i];
        pos += 56;

        const tls_ph = Elf64Phdr{
            .p_type = PtTls,
            .p_flags = PfR,
            .p_offset = tls_file_off,
            .p_vaddr = tls_vaddr,
            .p_paddr = tls_vaddr,
            .p_filesz = image.tls.len,
            .p_memsz = image.tls.len + image.tls_zero_fill_size,
            .p_align = image.tls_alignment,
        };
        const tls_ph_bytes = std.mem.asBytes(&tls_ph);
        for (0..tls_ph_bytes.len) |i| buf[pos + @as(u64, i)] = tls_ph_bytes[i];
        pos += 56;
    }

    // ---- .text content ----
    for (full_text, 0..full_text.len) |b, i| {
        buf[text_file_off + @as(u64, i)] = b;
    }
    // Patch absolute 32-bit reloc sites in .text: the sites hold merged-image
    // offsets (base 0), the image loads at `text_vaddr`, and there is no
    // relocation processing after load (ET_EXEC, no PIE), so add the base.
    for (image.abs32_sites.items) |site| {
        const off = text_file_off + site;
        const cur = readU32(buf, @intCast(off));
        const patched: u32 = @truncate(@as(u64, cur) + text_vaddr);
        buf[off] = @truncate(patched);
        buf[off + 1] = @truncate(patched >> 8);
        buf[off + 2] = @truncate(patched >> 16);
        buf[off + 3] = @truncate(patched >> 24);
    }
    // ---- .data content ----
    for (data, 0..data.len) |b, i| {
        buf[data_file_off + @as(u64, i)] = b;
    }
    // Patch absolute 64-bit reloc sites in .data. The relocation applier has
    // already included the complete text-to-data gap (entry stub plus any
    // page padding), so only the text segment's VA base remains to be added.
    for (image.addr64_sites.items) |site| {
        const off = data_file_off + site;
        const cur = readU64(buf, @intCast(off));
        const patched = cur + text_vaddr;
        var i: u6 = 0;
        while (i < 8) : (i += 1) {
            buf[off + i] = @truncate(patched >> (i * 8));
        }
    }
    if (emit_tls) {
        for (image.tls, 0..image.tls.len) |b, i| buf[tls_file_off + @as(u64, i)] = b;
    }

    return buf;
}

/// Write the buffer to `exe_path` (no extension on Linux).
pub fn writeExecutableElfToFile(
    io: std.Io,
    exe_path: []const u8,
    buf: []u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = buf });
}

test "ELF writer emits PT_TLS and initializes TLS before main" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var symbols = std.StringHashMap(ferro_types.ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    try symbols.put("_main", .{ .section = ".text", .value = 0 });
    try symbols.put("wfr_std_init_tls", .{ .section = ".text", .value = 0 });

    var text: [1]u8 = .{0xc3};
    var data: [4]u8 = @splat(0);
    var tls: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var image = MergedImage{
        .text = &text,
        .data = &data,
        .bss_size = 0,
        .tls = &tls,
        .tls_zero_fill_size = 8,
        .tls_alignment = 8,
        .symbols = symbols,
        .import_thunks = .empty,
        .import_desc_addr = 0,
        .import_desc_size = 0,
        .abs32_sites = .empty,
        .addr64_sites = .empty,
    };
    const buf = try writeExecutableElf(&image, 0, gpa);
    defer gpa.free(buf);

    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, buf[56..58], .little));
    const phdrs = buf[64 .. 64 + 4 * 56];
    try testing.expectEqual(@as(u64, 0), readU64(phdrs, 8)); // headers are mapped
    try testing.expectEqual(PfR | PfX, readU32(phdrs, 4));
    try testing.expectEqual(@as(u64, 0x1000), readU64(phdrs, 56 + 8)); // page-separated data
    try testing.expectEqual(PfR | PfW, readU32(phdrs, 56 + 4));

    const tls_load = phdrs[112..168];
    try testing.expectEqual(PtLoad, readU32(tls_load, 0));
    try testing.expectEqual(PfR, readU32(tls_load, 4));
    try testing.expectEqual(@as(u64, 8), readU64(tls_load, 32));
    try testing.expectEqual(@as(u64, 8), readU64(tls_load, 40));
    const tls_ph = phdrs[168..224];
    try testing.expectEqual(PtTls, readU32(tls_ph, 0));
    try testing.expectEqual(@as(u64, 8), readU64(tls_ph, 32));
    try testing.expectEqual(@as(u64, 16), readU64(tls_ph, 40));
    try testing.expectEqual(@as(u64, 8), readU64(tls_ph, 48));

    const stub = buf[64 + 4 * 56 + text.len ..][0..34];
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xbf, 0x40, 0x00, 0x40, 0x00, 0, 0, 0, 0 }, stub[0..10]);
    try testing.expectEqualSlices(u8, &.{ 0xbe, 4, 0, 0, 0 }, stub[10..15]);
    try testing.expectEqual(@as(u8, 0xe8), stub[15]); // init TLS
    try testing.expectEqual(@as(u8, 0xe8), stub[20]); // _main
}
