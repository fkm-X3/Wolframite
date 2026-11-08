//! `disasm` — Tungsten-aware disassembler for object files.
//!
//! Parses a Tungsten-emitted relocatable object (ELF64 on Linux, PE/COFF on
//! Windows) and disassembles each `.text` function, annotating function
//! symbols, relocation sites, and raw instruction bytes.
//!
//! Reuses the x86-64 decoder from `check_codegen.zig` and the `ferro_reader`
//! object reader, so no ELF/PE parsing is re-implemented here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const Object = ferro_types.Object;
const Section = ferro_types.Section;
const Relocation = ferro_types.Relocation;
const RelocKind = ferro_types.RelocKind;
const check_codegen = @import("check_codegen.zig");
const DecodedInstruction = check_codegen.DecodedInstruction;
const decodeInstruction = check_codegen.decodeInstruction;

pub const DisasmError = error{
    ObjectReadFailed,
    NoTextSection,
};

/// Function symbol recorded in .text: name, offset within .text, size in bytes.
const FuncSym = struct {
    name: []const u8,
    offset: u64,
    size: u64,
};

/// A single annotated instruction line.
pub const InstLine = struct {
    /// Byte offset within `.text`.
    offset: u64,
    /// Hex bytes of the instruction.
    bytes: []const u8,
    /// Disassembly mnemonic + operands (text form).
    text: []const u8,
    /// Inline annotation (relocation target), or empty.
    annotation: []const u8,
};

/// One function's disassembly.
pub const FuncDisasm = struct {
    name: []const u8,
    offset: u64,
    size: u64,
    lines: std.ArrayList(InstLine),
    pub fn deinit(self: *FuncDisasm, gpa: Allocator) void {
        for (self.lines.items) |*l| {
            gpa.free(l.text);
            gpa.free(l.annotation);
            gpa.free(l.bytes);
        }
        self.lines.deinit(gpa);
    }
};

/// Full disassembly report: one entry per `.text` function.
pub const Report = struct {
    funcs: std.ArrayList(FuncDisasm),
    pub fn deinit(self: *Report, gpa: Allocator) void {
        for (self.funcs.items) |*f| f.deinit(gpa);
        self.funcs.deinit(gpa);
    }
};

/// Disassemble every `.text` function in `obj`. Returns a `Report` the caller
/// must deinit.
pub fn disassembleObject(gpa: Allocator, obj: *const Object) !Report {
    const text_sec = findSection(obj, ".text") orelse return error.NoTextSection;
    const text = text_sec.content;

    // Build function map: symbol name -> (offset, size) within .text.
    var funcs = std.ArrayList(FuncSym).empty;
    for (obj.symbols.items) |sym| {
        if (sym.section == null) continue;
        if (!std.mem.eql(u8, sym.section.?, ".text")) continue;
        if (sym.name.len == 0) continue;
        const name = try gpa.dupe(u8, sym.name);
        try funcs.append(gpa, .{ .name = name, .offset = sym.value, .size = sym.size });
    }
    defer { for (funcs.items) |*f| gpa.free(f.name); funcs.deinit(gpa); }
    std.mem.sort(FuncSym, funcs.items, {}, byOffset);

    // Collect .text relocations for inline annotation (linear scan per
    // instruction keeps the code simple and avoids a second index structure).
    var text_relocs = std.ArrayList(Relocation).empty;
    errdefer text_relocs.deinit(gpa);
    for (obj.relocations.items) |rel| {
        if (rel.section_idx == 1) {
            try text_relocs.append(gpa, rel);
        }
    }

    var report = Report{ .funcs = .empty };
    errdefer report.deinit(gpa);

    var pc: u64 = 0;
    while (pc < text.len) {
        const func = findFuncAt(funcs.items, pc);
        const func_name = if (func) |f| f.name else "";
        const func_end = if (func) |f| @min(f.offset + f.size, text.len) else text.len;

        // report owns this FuncDisasm from the start, so any error is cleaned
        // up by report.deinit via the errdefer above.
        try report.funcs.append(gpa, .{
            .name = func_name,
            .offset = if (func) |f| f.offset else pc,
            .size = if (func) |f| f.size else func_end - pc,
            .lines = .empty,
        });
        const fd = &report.funcs.items[report.funcs.items.len - 1];

        var cur: u64 = pc;
        while (cur < func_end) {
            const decoded = if (decodeInstruction(text[cur..])) |d| d else |_| {
                try fd.lines.append(gpa, .{
                    .offset = cur,
                    .bytes = try gpa.dupe(u8, text[cur..func_end]),
                    .text = try gpa.dupe(u8, "<undecodable>"),
                    .annotation = try gpa.dupe(u8, ""),
                });
                cur = func_end; // advance past so we don't loop forever
                break;
            };
            const inst_bytes = text[cur .. cur + @as(usize, decoded.len)];
            const mnemonic = try mnemonicText(gpa, decoded);

            var annotation: []const u8 = try gpa.dupe(u8, "");
            annotation = try relocAnnotationFor(gpa, text_relocs.items, cur, @as(u64, decoded.len));

            try fd.lines.append(gpa, .{
                .offset = cur,
                .bytes = try gpa.dupe(u8, inst_bytes),
                .text = mnemonic,
                .annotation = annotation,
            });
            cur += @as(u64, decoded.len);
        }

        pc = cur;
    }

    return report;
}

/// Build the inline relocation annotation string for all relocations at
/// `offset`, or an empty string when none apply.
fn relocAnnotationFor(gpa: Allocator, relocs: []const Relocation, offset: u64, inst_len: u64) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var first = true;
    for (relocs) |rel| {
        if (rel.offset < offset or rel.offset >= offset + inst_len) continue;
        if (!first) try out.appendSlice(gpa, ", ");
        first = false;
        const s = try std.fmt.allocPrint(gpa, "{s} {s} +{d}", .{relocKindName(rel.kind), rel.symbol, rel.addend});
        defer gpa.free(s);
        try out.appendSlice(gpa, s);
    }
    if (first) return try gpa.dupe(u8, "");
    return try out.toOwnedSlice(gpa);
}

fn relocKindName(kind: RelocKind) []const u8 {
    return switch (kind) {
        .pc32 => "PC32",
        .addr64 => "ADDR64",
    };
}

fn byOffset(_: void, a: FuncSym, b: FuncSym) bool {
    return a.offset < b.offset;
}

fn findSection(obj: *const Object, name: []const u8) ?*const Section {
    for (obj.sections.items) |*sec| {
        if (std.mem.eql(u8, sec.name, name)) return sec;
    }
    return null;
}

fn findFuncAt(funcs: []const FuncSym, pc: u64) ?*const FuncSym {
    var lo: usize = 0;
    var hi = funcs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const f = funcs[mid];
        if (pc < f.offset) {
            hi = mid;
        } else if (pc >= f.offset + f.size) {
            lo = mid + 1;
        } else {
            return &funcs[mid];
        }
    }
    return null;
}

fn mnemonicText(gpa: Allocator, d: DecodedInstruction) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    if (d.has_rex) {
        const s = try std.fmt.allocPrint(gpa, "{x} ", .{d.rex});
        defer gpa.free(s);
        try out.appendSlice(gpa, s);
    }
    const s0 = try std.fmt.allocPrint(gpa, "{x}", .{d.opcode});
    defer gpa.free(s0);
    try out.appendSlice(gpa, s0);
    if (d.opcode2 != 0) {
        const s2 = try std.fmt.allocPrint(gpa, " {x}", .{d.opcode2});
        defer gpa.free(s2);
        try out.appendSlice(gpa, s2);
    }
    if (d.has_modrm) {
        const s3 = try std.fmt.allocPrint(gpa, " {x}", .{d.modrm});
        defer gpa.free(s3);
        try out.appendSlice(gpa, s3);
    }
    if (d.has_sib) {
        const s4 = try std.fmt.allocPrint(gpa, " {x}", .{d.sib});
        defer gpa.free(s4);
        try out.appendSlice(gpa, s4);
    }
    if (d.disp_len > 0) {
        const s5 = try std.fmt.allocPrint(gpa, " disp{d}={d}", .{d.disp_len, d.disp});
        defer gpa.free(s5);
        try out.appendSlice(gpa, s5);
    }
    if (d.imm_len > 0) {
        const s6 = try std.fmt.allocPrint(gpa, " imm{d}={x}", .{d.imm_len, d.imm});
        defer gpa.free(s6);
        try out.appendSlice(gpa, s6);
    }
    return try out.toOwnedSlice(gpa);
}
