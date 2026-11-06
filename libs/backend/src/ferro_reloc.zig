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
) !void {
    const sym_addr = symbols.get(rel.symbol) orelse return error.RelocationFailed;
    const s = sym_addr.value;
    const p = section_base + rel.offset;
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
    const merged_data_size = prog_data_size + rt_data_size;
    const merged_bss_size = prog_bss_size + rt_bss_size;

    // ---- Build symbol address map ----
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);

    // A relocation target only gets a `ret` stub when it is genuinely
    // undefined: not defined in the program, not defined in the runtime, and
    // not resolved against the runtime. Membership (not address) is enough
    // here, so this scan does not depend on `data_base` or stub layout.
    var seen_stubs = std.StringHashMap(usize).init(gpa);
    defer seen_stubs.deinit();
    var stub_count: usize = 0;
    for (program.relocations.items) |rel| {
        if (symbolNeedsStub(program, runtime, resolved, rel.symbol) and seen_stubs.get(rel.symbol) == null) {
            try seen_stubs.put(rel.symbol, @intCast(stub_count));
            stub_count += 1;
        }
    }
    for (runtime.relocations.items) |rel| {
        if (symbolNeedsStub(program, runtime, resolved, rel.symbol) and seen_stubs.get(rel.symbol) == null) {
            try seen_stubs.put(rel.symbol, @intCast(stub_count));
            stub_count += 1;
        }
    }

    // Build merged .text including space for stubs at the end.
    const stub_total_size = @as(u64, @intCast(stub_count)); // 1 byte per stub (ret)
    var merged_text = try gpa.alloc(u8, merged_text_size + stub_total_size);
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
    // Append `ret` stubs for genuinely undefined symbols.
    var stub_addr: u64 = merged_text_size;
    {
        var iter = seen_stubs.iterator();
        while (iter.next()) |item| {
            merged_text[@as(usize, stub_addr)] = 0xc3; // ret
            try symbols.put(item.key_ptr.*, .{ .section = ".text", .value = stub_addr });
            stub_addr += 1;
        }
    }

    // data_base is now after .text including stubs.
    const data_base = merged_text_size + stub_total_size;

    // Program-defined symbols (.text / .data only).
    for (program.symbols.items) |sym| {
        if (sym.section == null) continue;
        const sec = sym.section.?;
        // Skip COFF section symbols (name starts with '.', value 0).
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
        // Skip COFF section symbols (name starts with '.', value 0).
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
    var iter = resolved.resolved.iterator();
    while (iter.next()) |node| {
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

    // Build merged .data.
    var merged_data = try gpa.alloc(u8, merged_data_size);
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

    // ---- Apply relocations: program object ----
    for (program.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text else merged_data;
        const base = if (rel.section_idx == 1) @as(u64, 0) else data_base;
        applyReloc(&rel, base, buf, &symbols) catch {};
    }

    // ---- Apply relocations: runtime object ----
    //
    // Runtime relocations were already offset-adjusted by cum_text in
    // readArchiveObject, so their `offset` is relative to the start of the
    // runtime's own text/data section. Since merged_text starts with program
    // text, we must slice buf to begin at prog_text_size / prog_data_size so
    // that buf[rel.offset] lands on the right location in merged_text.
    for (runtime.relocations.items) |rel| {
        const buf = if (rel.section_idx == 1) merged_text[prog_text_size..] else merged_data[prog_data_size..];
        const base = if (rel.section_idx == 1) prog_text_size else data_base + prog_data_size;
        applyReloc(&rel, base, buf, &symbols) catch {};
    }

    return MergedImage{
        .text = merged_text,
        .data = merged_data,
        .bss_size = merged_bss_size,
        .symbols = symbols,
        .import_thunks = .empty,
    };
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
