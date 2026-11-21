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
    target: ferro_types.Target,
) !void {
    _ = target;
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
            const addend_u64: u64 = @bitCast(rel.addend);
            const abs: u64 = s +% addend_u64;
            if (off + 8 > buf.len) return error.RelocationFailed;
            const bytes = std.mem.asBytes(&abs);
            for (bytes, 0..8) |b, i| {
                buf[off + i] = b;
            }
        },
        .abs32 => {
            // S + A, 32-bit absolute.
            const addend_i64: i64 = rel.addend;
            const abs: i64 = @as(i64, @bitCast(s)) +% addend_i64;
            if (abs < @as(i64, std.math.minInt(i32)) or abs > @as(i64, std.math.maxInt(i32))) return error.RelocationFailed;
            if (off + 4 > buf.len) return error.RelocationFailed;
            const v: i32 = @intCast(abs);
            const bytes = std.mem.asBytes(&v);
            for (bytes, 0..4) |b, i| {
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
    var prog_undef_names = std.ArrayList([]const u8).empty;
    defer prog_undef_names.deinit(gpa);

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
            try appendUndef(&prog_undef_names, gpa, rel.symbol);
        }
    }
    for (runtime.relocations.items) |rel| {
        if (symbolNeedsStub(program, runtime, resolved, rel.symbol)) {
            try appendUndef(&undef_names, gpa, rel.symbol);
        }
    }

    // Split undefined symbols into OS imports (Windows kernel32/ntdll) vs.
    // unresolved. On Linux (or for any non-import name) there are no import
    // thunks: an undefined symbol referenced by the *program* is a hard error
    // rather than a silent `ret` stub. Symbols that only the runtime archive
    // references internally (e.g. compiler-rt helpers) keep a `ret` stub.
    var import_names = std.ArrayList([]const u8).empty;
    defer import_names.deinit(gpa);
    var import_dlls = std.ArrayList(ferro_types.OsImportDll).empty;
    defer import_dlls.deinit(gpa);
    var stub_total_size: u64 = 0;
    for (undef_names.items) |name| {
        if (ferro_types.osImportDll(name, target)) |dll| {
            try import_names.append(gpa, name);
            try import_dlls.append(gpa, dll);
            stub_total_size += 6;
        } else {
            // Is this name referenced by the program object?
            var from_prog = false;
            for (prog_undef_names.items) |pn| {
                if (std.mem.eql(u8, pn, name)) {
                    from_prog = true;
                    break;
                }
            }
            if (from_prog) return error.UndefinedSymbol;
            // Runtime-internal: keep a 1-byte `ret` stub.
            stub_total_size += 1;
        }
    }

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
        if (ferro_types.isOsImport(name, target)) {
            cur += 6;
        } else {
            cur += 1;
        }
    }

    // Fill runtime-internal stubs with `ret`.
    for (undef_names.items) |name| {
        if (ferro_types.isOsImport(name, target)) continue;
        const off = stub_offsets.get(name).?;
        merged_text[@as(usize, off)] = 0xc3; // ret
        try symbols.put(name, .{ .section = ".text", .value = off });
    }

    // data_base is now after .text including stubs/thunks. On Windows the PE
    // writer appends the synthesized entry stub (`pe_entry_stub_size` bytes)
    // to merged .text before .data begins, so .data's VA is the page-aligned
    // address after `data_base + pe_entry_stub_size`. The gap must be taken
    // from that layout or every .data reference is off by up to the stub
    // size whenever `data_base + stub` crosses a page boundary.
    const data_base = merged_text_size + stub_total_size;
    const data_va_gap: u64 = switch (target) {
        .linux_x86_64 => 0,
        .windows_x86_64 => blk: {
            const aln: u64 = 0x1000;
            const data_start = data_base + ferro_types.pe_entry_stub_size;
            break :blk (data_start + aln - 1) / aln * aln - data_base;
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

    // ---- Build the PE import block (per-DLL IAT/INT arrays, hint/name
    // entries, DLL names, then the descriptor array). The block is laid out
    // and filled in its own buffer first so `merged_data` can be allocated
    // with the exact final size; it is appended after the program and
    // runtime data. There is one descriptor per used DLL, in the fixed
    // emission order (`os_import_dll_order`), followed by the all-zero
    // terminator descriptor the loader expects.
    var import_block = std.ArrayList(u8).empty;
    defer import_block.deinit(gpa);
    var import_thunks = std.ArrayList(ImportThunk).empty;
    var import_desc_addr: u64 = 0;
    var import_desc_size: u64 = 0;
    if (import_names.items.len > 0) {
        const block_data_off = prog_data_size + rt_data_size; // offset within merged .data
        const block_merged_base = data_base + block_data_off; // merged-image address

        // PE RVA conversion helpers (PE layout constants). These must match
        // `writeExecutablePe`: .data's VA is the page-aligned address after
        // merged .text plus the synthesized entry stub.
        const pe_text_base: u64 = 0x1000;
        const pe_data_vaddr = (pe_text_base + data_base + ferro_types.pe_entry_stub_size + 0xFFF) & ~@as(u64, 0xFFF);
        const toDataRva = struct {
            fn f(merged_addr: u64, text_len: u64, data_vaddr: u64) u64 {
                return data_vaddr + (merged_addr - text_len);
            }
        }.f;

        // Slot index of each DLL in the fixed emission order.
        const dllSlot = struct {
            fn f(dll: ferro_types.OsImportDll) usize {
                for (ferro_types.os_import_dll_order, 0..) |d, i| {
                    if (d == dll) return i;
                }
                unreachable;
            }
        }.f;

        const group_count = ferro_types.os_import_dll_order.len;
        var counts: [group_count]usize = @splat(0);
        for (import_dlls.items) |d| counts[dllSlot(d)] += 1;
        var used_dlls: usize = 0;
        for (counts) |n| {
            if (n > 0) used_dlls += 1;
        }

        // ---- Pass 1: layout. ----
        var iat_off: [group_count]u64 = undefined;
        var int_off: [group_count]u64 = undefined;
        var dll_name_off: [group_count]u64 = undefined;
        const name_entry_off = try gpa.alloc(u64, import_names.items.len);
        defer gpa.free(name_entry_off);

        var o: u64 = 0;
        for (ferro_types.os_import_dll_order, 0..) |_, gi| {
            if (counts[gi] == 0) continue;
            iat_off[gi] = o;
            o += @as(u64, counts[gi] + 1) * 8; // IAT + terminator
            int_off[gi] = o;
            o += @as(u64, counts[gi] + 1) * 8; // INT + terminator
        }
        for (import_names.items, 0..) |name, i| {
            name_entry_off[i] = o;
            o += 2 + name.len + 1; // hint + name + NUL
            if (o % 2 != 0) o += 1; // next entry starts 2-aligned
        }
        for (ferro_types.os_import_dll_order, 0..) |dll, gi| {
            if (counts[gi] == 0) continue;
            dll_name_off[gi] = o;
            o += dll.dllName().len + 1;
        }
        o = (o + 3) & ~@as(u64, 3); // descriptors hold u32s: 4-align
        const desc_array_off = o;
        o += @as(u64, used_dlls + 1) * 20; // descriptors + terminator

        // ---- Pass 2: fill. ----
        const block = try gpa.alloc(u8, @intCast(o));
        defer gpa.free(block);
        for (block) |*b| b.* = 0;

        for (ferro_types.os_import_dll_order, 0..) |dll, gi| {
            if (counts[gi] == 0) continue;
            const dll_name = dll.dllName();
            for (dll_name, 0..) |c, k| {
                block[@as(usize, dll_name_off[gi]) + k] = c;
            }
        }
        var slot: [group_count]usize = @splat(0);
        for (import_names.items, 0..) |name, i| {
            const gi = dllSlot(import_dlls.items[i]);
            const k = slot[gi];
            slot[gi] += 1;
            const name_rva = toDataRva(block_merged_base + name_entry_off[i], data_base, pe_data_vaddr);
            writeU64At(block, iat_off[gi] + @as(u64, k) * 8, name_rva);
            writeU64At(block, int_off[gi] + @as(u64, k) * 8, name_rva);
            // hint (2 bytes, 0) + name + NUL — hint and NUL already zero.
            for (name, 0..) |c, kk| {
                block[@as(usize, name_entry_off[i]) + 2 + kk] = c;
            }
        }
        var desc_i: usize = 0;
        for (ferro_types.os_import_dll_order, 0..) |_, gi| {
            if (counts[gi] == 0) continue;
            const d = desc_array_off + @as(u64, desc_i) * 20;
            desc_i += 1;
            writeU32At(block, d + 0, @truncate(toDataRva(block_merged_base + int_off[gi], data_base, pe_data_vaddr))); // OriginalFirstThunk
            writeU32At(block, d + 4, 0); // TimeDateStamp
            writeU32At(block, d + 8, 0); // ForwarderChain
            writeU32At(block, d + 12, @truncate(toDataRva(block_merged_base + dll_name_off[gi], data_base, pe_data_vaddr))); // Name
            writeU32At(block, d + 16, @truncate(toDataRva(block_merged_base + iat_off[gi], data_base, pe_data_vaddr))); // FirstThunk
        }
        // The all-zero terminator descriptor is already zero.

        import_desc_addr = block_merged_base + desc_array_off;
        import_desc_size = @as(u64, used_dlls + 1) * 20;

        // Fill import thunks (jmp [rip+disp32] into the owning DLL's IAT
        // slot). Each thunk is the 6 bytes `ff 25 disp32`.
        @memset(&slot, 0);
        for (import_names.items, 0..) |name, i| {
            const gi = dllSlot(import_dlls.items[i]);
            const k = slot[gi];
            slot[gi] += 1;
            const thunk_off = stub_offsets.get(name).?;
            const iat_slot_merged = block_merged_base + iat_off[gi] + @as(u64, k) * 8;
            const iat_slot_rva = toDataRva(iat_slot_merged, data_base, pe_data_vaddr);
            const thunk_rva = pe_text_base + thunk_off;
            // disp for jmp [rip+disp]: target RIP-relative = iat_slot_rva - (thunk_rva + 6)
            const disp: i64 = @as(i64, @bitCast(iat_slot_rva)) - @as(i64, @bitCast(thunk_rva + 6));
            merged_text[@as(usize, thunk_off)] = 0xff;
            merged_text[@as(usize, thunk_off + 1)] = 0x25;
            const disp32: i32 = @intCast(disp);
            const bytes = std.mem.asBytes(&disp32);
            for (0..4) |kk| {
                merged_text[@as(usize, thunk_off + 2 + kk)] = bytes[kk];
            }

            try import_thunks.append(gpa, .{
                .name = try gpa.dupe(u8, name),
                .rva = thunk_off,
                .thunk_addr = thunk_off,
                .iat_slot_addr = iat_slot_merged,
                .name_entry_addr = block_merged_base + name_entry_off[i],
            });
        }

        for (block) |b| try import_block.append(gpa, b);
    }

    // Build merged .data: program data, then runtime data, then the import
    // block (whose IAT slots the Windows loader patches at load time).
    const merged_data_size = prog_data_size + rt_data_size + import_block.items.len;
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
    for (import_block.items, 0..) |b, i| {
        merged_data[@as(usize, prog_data_size) + @as(usize, rt_data_size) + i] = b;
    }

    var abs32_sites = std.ArrayList(u64).empty;
    var addr64_sites = std.ArrayList(u64).empty;
    errdefer abs32_sites.deinit(gpa);
    errdefer addr64_sites.deinit(gpa);

    // ---- Apply relocations: program object ----
    for (program.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text else merged_data;
        const base = if (rel.section_idx == 1) @as(u64, 0) else data_base;
        applyReloc(&rel, base, buf, &symbols, data_va_gap, target) catch {};
        if (rel.kind == .abs32 and rel.section_idx == 1) {
            try abs32_sites.append(gpa, rel.offset);
        }
        if (rel.kind == .addr64 and rel.section_idx == 2) {
            try addr64_sites.append(gpa, rel.offset);
        }
    }

    // ---- Apply relocations: runtime object ----
    for (runtime.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text[prog_text_size..] else merged_data[prog_data_size..];
        const base = if (rel.section_idx == 1) prog_text_size else data_base + prog_data_size;
        applyReloc(&rel, base, buf, &symbols, data_va_gap, target) catch {};
        if (rel.kind == .abs32 and rel.section_idx == 1) {
            try abs32_sites.append(gpa, prog_text_size + rel.offset);
        }
        if (rel.kind == .addr64 and rel.section_idx == 2) {
            // Merged-.data-relative offset: the executable writers patch at
            // `data_file_off + site`, so the site must not include the
            // merged text length. (Including it made the ELF writer patch
            // past .data — and out of the file buffer entirely.)
            try addr64_sites.append(gpa, prog_data_size + rel.offset);
        }
    }

    return MergedImage{
        .text = merged_text,
        .data = merged_data,
        .bss_size = merged_bss_size,
        .symbols = symbols,
        .import_thunks = import_thunks,
        .import_desc_addr = import_desc_addr,
        .import_desc_size = import_desc_size,
        .abs32_sites = abs32_sites,
        .addr64_sites = addr64_sites,
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
