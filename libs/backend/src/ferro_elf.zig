//! Ferro ELF64 executable writer (Linux).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const MergedImage = ferro_types.MergedImage;

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
pub fn writeExecutableElfToFile(
    io: std.Io,
    exe_path: []const u8,
    buf: []u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = buf });
}

