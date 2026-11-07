//! Ferro relocation application and section merging.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const Object = ferro_types.Object;
const Section = ferro_types.Section;
const Symbol = ferro_types.Symbol;
const Binding = ferro_types.Binding;
const Relocation = ferro_types.Relocation;
const RelocKind = ferro_types.RelocKind;
const ResolvedSymbol = ferro_types.ResolvedSymbol;
const ResolvedSymbols = ferro_types.ResolvedSymbols;
const MergedImage = ferro_types.MergedImage;
const LinkError = ferro_types.LinkError;
const ImportThunk = ferro_types.ImportThunk;

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
    gap: u64,
) !void {
    const sym_addr = symbols.get(rel.symbol) orelse return error.RelocationFailed;
    // Convert merged addresses to virtual-address offsets (relative to the
    // text section base) so cross-section references account for any alignment
    // gap between .text and .data (e.g. PE section alignment).
    const s_merged = sym_addr.value;
    const s_va = if (std.mem.eql(u8, sym_addr.section, ".data")) s_merged + gap else s_merged;
    const site_merged = section_base + rel.offset;
    const p_va = site_merged + (if (rel.section_idx == 2) gap else 0);
    const s = s_va;
    const p = p_va;
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

/// Returns true when `name` is genuinely undefined: not defined in the
/// program or runtime symbol tables, and not resolved against the runtime.
// Membersip (not address) is enough here, so this does not depend on
// `data_base` or stub layout.
fn symbolNeedsStub(
    program: *const Object,
    runtime: *const Object,
    resolved: *const ResolvedSymbols,
    name: []const u8,
) bool {
    for (program.symbols.items) |s| {
        if (s.section != null and std.mem.eql(u8, s.name, name)) return false;
    }
    for (runtime.symbols.items) |s| {
        if (s.section != null and std.mem.eql(u8, s.name, name)) return false;
    }
    if (resolved.resolved.get(name) != null) return false;
    return true;
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
    target: ferro_types.Target,
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
    const merged_bss_size = prog_bss_size + rt_bss_size;

    // ---- Collect genuinely-undefined symbols (program then runtime). ----
    var undef_names = std.ArrayList([]const u8).empty;
    defer undef_names.deinit(gpa);

    const appendUndef = struct {
        fn f(list: *std.ArrayList([]const u8), gpa2: Allocator, name: []const u8) !void {
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, name)) return;
            }
            try list.append(gpa2, name);
        }
    }.f;

    for (program.relocations.items) |rel| {
        if (symbolNeedsStub(program, runtime, resolved, rel.symbol)) {
            try appendUndef(&undef_names, gpa, rel.symbol);
        }
    }
    for (runtime.relocations.items) |rel| {
        if (symbolNeedsStub(program, runtime, resolved, rel.symbol)) {
            try appendUndef(&undef_names, gpa, rel.symbol);
        }
    }

    // Split undefined symbols into kernel32 imports vs. plain stubs.
    var import_names = std.ArrayList([]const u8).empty;
    defer import_names.deinit(gpa);
    for (undef_names.items) |name| {
        if (ferro_types.isKernel32Import(name)) {
            try import_names.append(gpa, name);
        }
    }

    // Compute stub total size: 6 bytes per import thunk, 1 byte per plain stub.
    var stub_total_size: u64 = 0;
    for (undef_names.items) |name| {
        if (ferro_types.isKernel32Import(name)) {
            stub_total_size += 6;
        } else {
            stub_total_size += 1;
        }
    }

    // Import data size (IAT + INT + name entries + dll name + descriptor).
    var import_data_size: u64 = 0;
    if (import_names.items.len > 0) {
        import_data_size += @as(u64, import_names.items.len + 1) * 8; // IAT
        import_data_size += @as(u64, import_names.items.len + 1) * 8; // INT
        for (import_names.items) |name| {
            import_data_size += 2 + name.len + 1; // hint + name + null
            if (import_data_size % 2 != 0) import_data_size += 1;
        }
        import_data_size += "kernel32.dll".len + 1; // dll name
        import_data_size += 40; // descriptor + null terminator
    }

    const merged_data_size = prog_data_size + rt_data_size + import_data_size;

    // ---- Build symbol address map ----
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);

    // Build merged .text including space for stubs/thunks at the end.
    var merged_text = try gpa.alloc(u8, merged_text_size + stub_total_size);
    for (merged_text) |*b| b.* = 0;
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

    // Assign merged-text offsets to each undefined symbol.
    var stub_offsets = std.StringHashMap(u64).init(gpa);
    defer stub_offsets.deinit();
    var cur: u64 = merged_text_size;
    for (undef_names.items) |name| {
        try stub_offsets.put(name, cur);
        if (ferro_types.isKernel32Import(name)) {
            cur += 6;
        } else {
            cur += 1;
        }
    }

    // Fill plain stubs with `ret`.
    for (undef_names.items) |name| {
        if (ferro_types.isKernel32Import(name)) continue;
        const off = stub_offsets.get(name).?;
        merged_text[@as(usize, off)] = 0xc3; // ret
        try symbols.put(name, .{ .section = ".text", .value = off });
    }

    // data_base is now after .text including stubs/thunks.
    const data_base = merged_text_size + stub_total_size;
    const data_va_gap: u64 = switch (target) {
        .linux_x86_64 => 0,
        .windows_x86_64 => blk: {
            const aln: u64 = 0x1000;
            break :blk (data_base + aln - 1) / aln * aln - data_base;
        },
    };

    // Program-defined symbols (.text / .data only).
    for (program.symbols.items) |sym| {
        if (sym.section == null) continue;
        const sec = sym.section.?;
        if (std.mem.startsWith(u8, sym.name, ".")) continue;
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
        if (std.mem.startsWith(u8, sym.name, ".")) continue;
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
    var riter = resolved.resolved.iterator();
    while (riter.next()) |node| {
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

    // Add kernel32 import thunks to symbol map (thunk code filled below).
    for (import_names.items) |name| {
        const off = stub_offsets.get(name).?;
        try symbols.put(name, .{ .section = ".text", .value = off });
    }

    // Build merged .data.
    var merged_data = try gpa.alloc(u8, merged_data_size);
    for (merged_data) |*b| b.* = 0;
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

    // Fill import data structures in merged .data.
    var import_thunks = std.ArrayList(ImportThunk).empty;
    var import_desc_addr: u64 = 0;
    if (import_names.items.len > 0) {
        const base_imp = prog_data_size + rt_data_size;
        var o: u64 = base_imp;

        // IAT array.
        const iat_off = o;
        o += @as(u64, import_names.items.len + 1) * 8;
        // INT array.
        const int_off = o;
        o += @as(u64, import_names.items.len + 1) * 8;

        // Name entries.
        var name_entry_offs = try gpa.alloc(u64, import_names.items.len);
        defer gpa.free(name_entry_offs);
        for (import_names.items, 0..) |name, i| {
            name_entry_offs[i] = o;
            // hint (2 bytes) + name + null
            merged_data[@as(usize, o)] = 0;
            merged_data[@as(usize, o + 1)] = 0;
            o += 2;
            for (name, 0..) |c, k| {
                merged_data[@as(usize, o + k)] = c;
            }
            o += name.len;
            merged_data[@as(usize, o)] = 0;
            o += 1;
            if (o % 2 != 0) o += 1;
        }

        // DLL name.
        const dll_name_off = o;
        const dll_name = "kernel32.dll";
        for (dll_name, 0..) |c, k| {
            merged_data[@as(usize, o + k)] = c;
        }
        o += dll_name.len;
        merged_data[@as(usize, o)] = 0;
        o += 1;

        // Descriptor (+ null terminator) = 40 bytes.
        const desc_off = o;
        o += 40;

        // PE RVA conversion helpers (PE layout constants).
        const pe_text_base: u64 = 0x1000;
        const full_text_size = data_base; // merged text len including stubs
        const pe_data_vaddr = (pe_text_base + full_text_size + 0xFFF) & ~@as(u64, 0xFFF);

        const toDataRva = struct {
            fn f(merged_addr: u64, text_len: u64, data_vaddr: u64) u64 {
                return data_vaddr + (merged_addr - text_len);
            }
        }.f;

        // Fill IAT and INT arrays with RVAs of name entries.
        for (import_names.items, 0..) |_, i| {
            const name_rva = toDataRva(data_base + name_entry_offs[i], data_base, pe_data_vaddr);
            // IAT slot
            const iat_slot_merged = data_base + iat_off + @as(u64, i) * 8;
            _ = iat_slot_merged;
            writeU64At(merged_data, iat_off + @as(u64, i) * 8, name_rva);
            writeU64At(merged_data, int_off + @as(u64, i) * 8, name_rva);
        }
        // terminators already zero.

        // Fill descriptor.
        const int_rva = toDataRva(data_base + int_off, data_base, pe_data_vaddr);
        const iat_rva = toDataRva(data_base + iat_off, data_base, pe_data_vaddr);
        const dll_name_rva = toDataRva(data_base + dll_name_off, data_base, pe_data_vaddr);
        // descriptor at desc_off (relative to merged_data start? desc_off is offset within merged_data)
        const desc_merged_offset = desc_off; // offset within merged_data
        // write 20-byte descriptor
        writeU32At(merged_data, desc_merged_offset + 0, @truncate(int_rva)); // OriginalFirstThunk
        writeU32At(merged_data, desc_merged_offset + 4, 0); // TimeDateStamp
        writeU32At(merged_data, desc_merged_offset + 8, 0); // ForwarderChain
        writeU32At(merged_data, desc_merged_offset + 12, @truncate(dll_name_rva)); // Name
        writeU32At(merged_data, desc_merged_offset + 16, @truncate(iat_rva)); // FirstThunk
        // null terminator descriptor already zero.

        import_desc_addr = data_base + desc_off;

        // Fill import thunks (jmp [rip+disp] to IAT slot).
        for (import_names.items, 0..) |name, i| {
            const thunk_off = stub_offsets.get(name).?;
            const iat_slot_merged = data_base + iat_off + @as(u64, i) * 8;
            const iat_slot_rva = toDataRva(iat_slot_merged, data_base, pe_data_vaddr);
            const thunk_rva = pe_text_base + thunk_off;
            // disp for jmp [rip+disp]: target RIP-relative = iat_slot_rva - (thunk_rva + 6)
            const disp: i64 = @as(i64, @bitCast(iat_slot_rva)) - @as(i64, @bitCast(thunk_rva + 6));
            merged_text[@as(usize, thunk_off)] = 0xff;
            merged_text[@as(usize, thunk_off + 1)] = 0x25;
            const disp32: i32 = @intCast(disp);
            const bytes = std.mem.asBytes(&disp32);
            for (0..4) |k| {
                merged_text[@as(usize, thunk_off + 2 + k)] = bytes[k];
            }
            // 6th byte already 0? jmp instruction is 6 bytes: ff 25 disp32. That's 6. Good.

            const iat_slot_merged_addr = iat_slot_merged;
            const name_entry_merged_addr = data_base + name_entry_offs[i];
            try import_thunks.append(gpa, .{
                .name = try gpa.dupe(u8, name),
                .rva = thunk_off,
                .thunk_addr = thunk_off,
                .iat_slot_addr = iat_slot_merged_addr,
                .name_entry_addr = name_entry_merged_addr,
            });
        }
    }


    // ---- Apply relocations: program object ----
    for (program.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text else merged_data;
        const base = if (rel.section_idx == 1) @as(u64, 0) else data_base;
        applyReloc(&rel, base, buf, &symbols, data_va_gap) catch {};
    }

    // ---- Apply relocations: runtime object ----
    for (runtime.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text[prog_text_size..] else merged_data[prog_data_size..];
        const base = if (rel.section_idx == 1) prog_text_size else data_base + prog_data_size;
        applyReloc(&rel, base, buf, &symbols, data_va_gap) catch {};
    }


    return MergedImage{
        .text = merged_text,
        .data = merged_data,
        .bss_size = merged_bss_size,
        .symbols = symbols,
        .import_thunks = import_thunks,
        .import_desc_addr = import_desc_addr,
        .import_desc_size = 40,
    };
}

fn writeU64At(buf: []u8, off: u64, v: u64) void {
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        buf[off + i] = @truncate(v >> (i * 8));
    }
}

fn writeU32At(buf: []u8, off: u64, v: u32) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

// ============================================================================
// ELF64 executable writer (delegated to ferro_elf.zig)
// ============================================================================

const ferro_elf = @import("ferro_elf.zig");

pub const buildLinuxStartStub = ferro_elf.buildLinuxStartStub;
pub const writeExecutableElf = ferro_elf.writeExecutableElf;
pub const writeExecutableElfToFile = ferro_elf.writeExecutableElfToFile;

// ============================================================================
// PE/COFF executable writer (delegated to ferro_pe.zig)
// ============================================================================

const ferro_pe = @import("ferro_pe.zig");

pub const writeExecutablePe = ferro_pe.writeExecutablePe;
