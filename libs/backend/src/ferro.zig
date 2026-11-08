//! Ferro — the Ferrotungsten linker.
//!
//! Ferro consumes Tungsten-emitted object files (ELF64 on Linux, PE/COFF on
//! Windows) plus the Wolframite runtime archive and produces a runnable
//! executable. It replaces the `nasm` + `zig cc` chain that `ore` used before
//! object emission existed.
//!
//! This file freezes the linker interface: the `linkObject` entry point, the
//! `Target` / `ObjectFormat` mapping, the `LinkOptions` surface, and the
//! `LinkError` set. The object reader, symbol resolver, relocation applier,
//! and executable writer are stubs here and are implemented later.
//!
//! See `libs/backend/docs/adr/adr_ferro_linker.md` for the decision record.

const std = @import("std");
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const ferro_types = @import("ferro_types.zig");

/// Re-export the shared Ferro type surface so `ferro.X` keeps working.
pub const Target = ferro_types.Target;
pub const ObjectFormat = ferro_types.ObjectFormat;
pub const objectFormat = ferro_types.objectFormat;
pub const Subsystem = ferro_types.Subsystem;

pub const LinkOptions = ferro_types.LinkOptions;
pub const defaultLinkOptions = ferro_types.defaultLinkOptions;

pub const LinkDescription = ferro_types.LinkDescription;
pub const LinkDescriptionError = ferro_types.LinkDescriptionError;
pub const parseTarget = ferro_types.parseTarget;
pub const parseSubsystem = ferro_types.parseSubsystem;
pub const linkOptionsFromDescription = ferro_types.linkOptionsFromDescription;

pub const LinkError = ferro_types.LinkError;
pub const Kernel32Imports = ferro_types.Kernel32Imports;
pub const isKernel32Import = ferro_types.isKernel32Import;

pub const Symbol = ferro_types.Symbol;
pub const Binding = ferro_types.Binding;
pub const Relocation = ferro_types.Relocation;
pub const RelocKind = ferro_types.RelocKind;
pub const Section = ferro_types.Section;
pub const Object = ferro_types.Object;
pub const ResolvedSymbol = ferro_types.ResolvedSymbol;
pub const ResolvedSymbols = ferro_types.ResolvedSymbols;
pub const ImportThunk = ferro_types.ImportThunk;
pub const MergedImage = ferro_types.MergedImage;

// ============================================================================
// Reader (delegated to ferro_reader.zig)
// ============================================================================

const ferro_reader = @import("ferro_reader.zig");

pub const readObject = ferro_reader.readObject;
pub const readArchiveObject = ferro_reader.readArchiveObject;

const readU16 = ferro_reader.readU16;
const readU32 = ferro_reader.readU32;
const readU64 = ferro_reader.readU64;
const readI64 = ferro_reader.readI64;


/// Resolve every undefined symbol in `program` against `runtime`.
///
/// Collects all defined symbols from both objects, then walks `program`'s
/// undefined symbols (those with `section == null`). For each one, looks it
/// up in `runtime`'s defined symbols. Symbols still unresolved are recorded
/// in `ResolvedSymbols.undefined`; if any remain, returns `LinkError.UndefinedSymbol`.
///
/// `entry_symbol` is reserved for entry-point wiring (implemented later); it
/// is always defined in the program object and is not consulted here.
// ============================================================================
// Symbol resolver (delegated to ferro_resolver.zig)
// ============================================================================

const ferro_resolver = @import("ferro_resolver.zig");

pub const resolveSymbols = ferro_resolver.resolveSymbols;

// ============================================================================
// Relocation application and section merging (delegated to ferro_reloc.zig)
// ============================================================================

const ferro_reloc = @import("ferro_reloc.zig");

pub const applyRelocations = ferro_reloc.applyRelocations;

const ferro_elf = @import("ferro_elf.zig");

pub const buildLinuxStartStub = ferro_elf.buildLinuxStartStub;
pub const writeExecutableElf = ferro_elf.writeExecutableElf;
pub const writeExecutableElfToFile = ferro_elf.writeExecutableElfToFile;

const ferro_pe = @import("ferro_pe.zig");

pub const writeExecutablePe = ferro_pe.writeExecutablePe;

// ============================================================================
// Executable writer dispatch
// ============================================================================

// ============================================================================
// Merged-image dump (debugging: `LinkOptions.dump`)
// ============================================================================

/// Return the raw section content (`.text` / `.data`) for a relocation's
/// section index, or null when the section is absent.
fn sectionContent(obj: *const Object, section_idx: u16) ?[]const u8 {
    const name = switch (section_idx) {
        1 => ".text",
        2 => ".data",
        else => return null,
    };
    for (obj.sections.items) |sec| {
        if (std.mem.eql(u8, sec.name, name)) return sec.content;
    }
    return null;
}

/// Size of a named section in `obj`, or 0 if absent.
fn sectionSize(obj: *const Object, name: []const u8) u64 {
    for (obj.sections.items) |sec| {
        if (std.mem.eql(u8, sec.name, name)) return sec.size;
    }
    return 0;
}

/// Print one object file's relocation list to `w` with computed
/// site/target/displacement before and after application. `section_base` is
/// the merged address where this object's `.text` / `.data` starts.
fn dumpObjectRelocs(
    w: *std.Io.File.Writer,
    label: []const u8,
    obj: *const Object,
    text_base: u64,
    data_base: u64,
    gap: u64,
    symbols: *const std.StringHashMap(ferro_types.ResolvedSymbol),
) void {
    const i32_min = @as(i64, std.math.minInt(i32));
    const i32_max = @as(i64, std.math.maxInt(i32));
    const near_limit: i64 = 1024;

    _ = w.interface.print("\n-- {s} relocations --\n", .{label}) catch {};
    for (obj.relocations.items) |rel| {
        const section_name = switch (rel.section_idx) {
            1 => ".text",
            2 => ".data",
            else => ".?",
        };
        const is_data = rel.section_idx == 2;
        const base = if (is_data) data_base else text_base;
        const site_merged = base + rel.offset;
        const p_va = site_merged + (if (is_data) gap else 0);

        // Raw bytes currently sitting at the relocation site (before patching).
        var before: [8]u8 = undefined;
        var before_len: usize = 0;
        if (sectionContent(obj, rel.section_idx)) |content| {
            before_len = @min(content.len, 8);
            var i: usize = 0;
            while (i < before_len) : (i += 1) {
                before[i] = content[@as(usize, @intCast(rel.offset)) + i];
            }
        }

        const sym_addr = symbols.get(rel.symbol);
        const s_merged = if (sym_addr) |a| a.value else 0;
        const s_va = s_merged + (if (is_data and sym_addr != null) gap else 0);

        var disp_after: i64 = 0;
        const kind_name = switch (rel.kind) {
            .pc32 => "PC32",
            .addr64 => "ADDR64",
        };
        switch (rel.kind) {
            .pc32 => {
                const s_va_i64: i64 = @intCast(s_va);
                const p_va_i64: i64 = @intCast(p_va);
                disp_after = s_va_i64 + rel.addend - p_va_i64;
            },
            .addr64 => {
                const s_merged_i64: i64 = @intCast(s_merged);
                disp_after = s_merged_i64 + rel.addend;
            },
        }

        const near_i32_limit = rel.kind == .pc32 and (
            @abs(disp_after - i32_min) <= near_limit or
            @abs(disp_after - i32_max) <= near_limit
        );

        _ = w.interface.print(
            "  {s} {s}+0x{x} -> {s} (0x{x}) | kind={s} addend={d} | before_disp={d} after_disp={d}{s}\n",
            .{
                section_name, section_name, rel.offset,
                if (sym_addr) |a| a.section else "?",
                if (sym_addr) |a| a.value else 0,
                kind_name, rel.addend,
                rel.addend,
                disp_after,
                if (near_i32_limit) "  <-- near i32 limit" else "",
            },
        ) catch {};

        var hex_buf: [16 * 2 + 3]u8 = undefined;
        var hex_len: usize = 0;
        var i: usize = 0;
        while (i < before_len) : (i += 1) {
            const nibbles = "0123456789abcdef";
            hex_buf[hex_len * 2] = nibbles[@intCast((before[i] >> 4) & 0x0f)];
            hex_buf[hex_len * 2 + 1] = nibbles[@intCast(before[i] & 0x0f)];
            hex_len += 1;
        }
        _ = w.interface.print("    before bytes: {s}\n", .{hex_buf[0..hex_len * 2]}) catch {};
    }
}

/// Print the merged image to stderr: section sizes, symbol addresses, and
/// every relocation's site/target/displacement before and after application.
/// PC32 displacements that sit within `near_limit` bytes of the i32 limit are
/// flagged, since they are the most likely to be truncated or mis-encoded.
fn dumpMergedImage(
    io: std.Io,
    image: *const MergedImage,
    program: *const Object,
    runtime: *const Object,
    options: LinkOptions,
) void {
    const Io = std.Io;
    var buf: [8192]u8 = undefined;
    var w = Io.File.Writer.init(.stderr(), io, &buf);

    const data_base = image.text.len;
    const gap = switch (options.target) {
        .linux_x86_64 => 0,
        .windows_x86_64 => (data_base + 0x1000 - 1) / 0x1000 * 0x1000 - data_base,
    };

    _ = w.interface.print("== Ferro merged image dump (target: {s}) ==\n", .{@tagName(options.target)}) catch {};

    const entry_addr = image.symbols.get(options.entry_symbol);
    if (entry_addr) |ea| {
        _ = w.interface.print("entry symbol: {s} -> {s}+0x{x} = 0x{x}\n", .{
            options.entry_symbol, ea.section, ea.value, ea.value,
        }) catch {};
    } else {
        _ = w.interface.print("entry symbol: {s} -> (not found)\n", .{options.entry_symbol}) catch {};
    }

    _ = w.interface.print(
        "merged .text: {d} bytes\nmerged .data: {d} bytes\nmerged .bss: {d} bytes\n",
        .{ image.text.len, image.data.len, image.bss_size },
    ) catch {};

    _ = w.interface.print("\n-- Symbols (merged address) --\n", .{}) catch {};
    var sym_iter = image.symbols.iterator();
    while (sym_iter.next()) |node| {
        const name = node.key_ptr.*;
        const addr = node.value_ptr.*;
        _ = w.interface.print("  {s}: {s}+0x{x} = 0x{x}\n", .{ name, addr.section, addr.value, addr.value }) catch {};
    }

    const prog_text_size = sectionSize(program, ".text");
    const prog_data_size = sectionSize(program, ".data");

    dumpObjectRelocs(&w, "program", program, 0, data_base, gap, &image.symbols);
    dumpObjectRelocs(&w, "runtime", runtime, prog_text_size, data_base + prog_data_size, gap, &image.symbols);

    _ = w.interface.flush() catch {};
}

/// Synthesize the platform entry point and write the final executable.
///
/// Linux: entry `_start` (at end of merged `.text`) calls `_main`.
/// Windows: entry `main` (at end of merged `.text`) calls `_main` per subsystem.
pub fn writeExecutable(
    image: *MergedImage,
    exe_path: []const u8,
    options: LinkOptions,
    gpa: Allocator,
    io: std.Io,
) !void {
    const main_addr = image.symbols.get(options.entry_symbol) orelse return error.UndefinedSymbol;

    switch (options.target) {
        .linux_x86_64 => {
            const buf = try writeExecutableElf(image, main_addr.value, gpa);
            defer gpa.free(buf);
            try writeExecutableElfToFile(io, exe_path, buf);
        },
        .windows_x86_64 => {
            const buf = try writeExecutablePe(image, main_addr.value, options.subsystem, gpa);
            defer gpa.free(buf);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = exe_path, .data = buf });
        },
    }
}

/// Link `object_path` (a Tungsten-emitted object) with the Wolframite runtime
/// `runtime_lib` into the executable `exe_path`.
///
/// This is the front-facing Ferro entry point used by `ore` and by any
/// Wolframite code driving the linker directly (`design.md`: link steps are
/// explicit Zig calls, not an `ld` script).
///
/// Steps (implemented later):
///   1. `readObject(object_path)`          — object reader
///   2. `readObject(runtime_lib)`          — object reader
///   3. `resolveSymbols(...)`              — symbol resolution
///   4. `applyRelocations(...)`            — relocation application
///   5. Synthesize entry (`entry_symbol` → platform entry)
///   6. `writeExecutable(...)`             — executable writer
///
/// On success `exe_path` is a runnable x86-64 executable for
/// `options.target`. Returns a `LinkError` on failure.
pub fn linkObject(
    io: std.Io,
    gpa: Allocator,
    object_path: []const u8,
    runtime_lib: []const u8,
    exe_path: []const u8,
    options: LinkOptions,
) !void {
    var object = try readObject(io, gpa, object_path);
    defer object.deinit(gpa);

    var runtime = try readObject(io, gpa, runtime_lib);
    defer runtime.deinit(gpa);

    var resolved = try resolveSymbols(&object, &runtime, options.entry_symbol, gpa);
    defer resolved.deinit(gpa);

    var image = try applyRelocations(&object, &runtime, &resolved, gpa, options.target);
    defer image.deinit(gpa);

    if (options.dump) {
        dumpMergedImage(io, &image, &object, &runtime, options);
    }

    try writeExecutable(&image, exe_path, options, gpa, io);
}

// ============================================================================
// Tests
// ============================================================================

test "objectFormat maps each target to its object format" {
    try std.testing.expectEqual(ObjectFormat.elf64, objectFormat(.linux_x86_64));
    try std.testing.expectEqual(ObjectFormat.pe_coff, objectFormat(.windows_x86_64));
}

test "defaultLinkOptions keeps target explicit and picks _main as entry" {
    const opts = defaultLinkOptions(.windows_x86_64);
    try std.testing.expectEqual(.windows_x86_64, opts.target);
    try std.testing.expectEqualStrings("_main", opts.entry_symbol);
    try std.testing.expectEqual(.console, opts.subsystem);
    try std.testing.expectEqual(false, opts.debug);
    try std.testing.expectEqual(false, opts.dump);
}

test "linkObject reports ObjectMissing for a nonexistent object file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const opts = defaultLinkOptions(.linux_x86_64);

    const result = linkObject(
        io,
        gpa,
        "does-not-exist-ferro-test.o",
        "also-does-not-exist.lib",
        "does-not-exist-ferro-test.exe",
        opts,
    );
    if (result) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.ObjectMissing, err);
    }
}

test "readObject reports ObjectMissing before touching the object reader" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const result = readObject(io, gpa, "does-not-exist-ferro-test.o");
    if (result) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.ObjectMissing, err);
    }
}

test "parseTarget accepts linux and windows (case-insensitive)" {
    try std.testing.expectEqual(.linux_x86_64, try parseTarget("linux"));
    try std.testing.expectEqual(.linux_x86_64, try parseTarget("Linux"));
    try std.testing.expectEqual(.linux_x86_64, try parseTarget("LINUX"));
    try std.testing.expectEqual(.windows_x86_64, try parseTarget("windows"));
    try std.testing.expectEqual(.windows_x86_64, try parseTarget("Windows"));
    if (parseTarget("osx")) |_| try std.testing.expect(false) else |err| {
        try std.testing.expectEqual(LinkDescriptionError.InvalidTarget, err);
    }
}

test "parseSubsystem accepts console and gui (case-insensitive)" {
    try std.testing.expectEqual(.console, try parseSubsystem("console"));
    try std.testing.expectEqual(.console, try parseSubsystem("Console"));
    try std.testing.expectEqual(.gui, try parseSubsystem("gui"));
    try std.testing.expectEqual(.gui, try parseSubsystem("GUI"));
    if (parseSubsystem("kernel")) |_| try std.testing.expect(false) else |err| {
        try std.testing.expectEqual(LinkDescriptionError.InvalidSubsystem, err);
    }
}

test "linkOptionsFromDescription maps a link description to LinkOptions" {
    const desc = LinkDescription{
        .target = "windows",
        .output = "hello.exe",
        .entry = "_main",
        .subsystem = "console",
        .runtime_lib = "wfr_std.lib",
        .input = "hello.o",
        .debug = false,
    };
    const opts = try linkOptionsFromDescription(desc);
    try std.testing.expectEqual(.windows_x86_64, opts.target);
    try std.testing.expectEqualStrings("_main", opts.entry_symbol);
    try std.testing.expectEqual(.console, opts.subsystem);
    try std.testing.expectEqual(false, opts.debug);
}

test "linkOptionsFromDescription rejects a bad target" {
    const desc = LinkDescription{
        .target = "osx",
        .output = "hello",
        .entry = "_main",
        .subsystem = "console",
        .runtime_lib = "wfr_std.lib",
        .input = "hello.o",
        .debug = false,
    };
    if (linkOptionsFromDescription(desc)) |_| try std.testing.expect(false) else |err| {
        try std.testing.expectEqual(LinkDescriptionError.InvalidTarget, err);
    }
}

test "readObject reads an ELF64 object Tungsten emitted (sections, symbols, relocations)" {
    const gpa = std.testing.allocator;
    const obj_elf = @import("obj_elf.zig");

    const text_bytes = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 }; // mov rax, rdi; ret
    const data_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0 };

    const symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "__g0", .section_idx = 2, .value = 0, .size = 6,
            .binding = .global, .is_func = false },
        obj_elf.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };

    const relocs = &.{
        obj_elf.Reloc{ .section_idx = 1, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 },
        obj_elf.Reloc{ .section_idx = 2, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 },
    };

    const input = obj_elf.ObjectInput{
        .text = &text_bytes,
        .data = &data_bytes,
        .bss_size = 0,
        .symbols = symbols,
        .relocs = relocs,
    };

    var w = obj_elf.Writer.init(gpa);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer gpa.free(bytes);

    const path = "ferro_read_elf_test.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    const io = std.testing.io;
    var object = try readObject(io, gpa, path);
    defer object.deinit(gpa);

    try std.testing.expectEqual(ObjectFormat.elf64, object.format);

    // Sections: NULL, .text, .data, .bss, .symtab, .strtab, .rela.text, .rela.data, .shstrtab
    try std.testing.expectEqual(9, object.sections.items.len);
    try std.testing.expectEqualSlices(u8, object.sections.items[1].content, &text_bytes);
    try std.testing.expectEqualSlices(u8, object.sections.items[2].content, &data_bytes);
    try std.testing.expectEqual(0, object.sections.items[3].content.len);

    // Symbols: STN_UNDEF (index 0) + _main + __g0 + puts.
    // `puts` is an undefined extern (SHN_UNDEF) so its section is null.
    try std.testing.expectEqual(4, object.symbols.items.len);
    // STN_UNDEF: null name, null section.
    try std.testing.expectEqualSlices(u8, object.symbols.items[0].name, &[_]u8{});
    try std.testing.expectEqual(null, object.symbols.items[0].section);
    try std.testing.expectEqualStrings("_main", object.symbols.items[1].name);
    try std.testing.expectEqualStrings(".text", object.symbols.items[1].section.?);
    try std.testing.expectEqualStrings("__g0", object.symbols.items[2].name);
    try std.testing.expectEqualStrings(".data", object.symbols.items[2].section.?);
    try std.testing.expectEqualStrings("puts", object.symbols.items[3].name);
    try std.testing.expectEqual(null, object.symbols.items[3].section);

    // Relocations: one PC32 in .text (puts), one ADDR64 in .data (__g0)
    try std.testing.expectEqual(2, object.relocations.items.len);
    try std.testing.expectEqualStrings("puts", object.relocations.items[0].symbol);
    try std.testing.expectEqual(.pc32, object.relocations.items[0].kind);
    try std.testing.expectEqual(-4, object.relocations.items[0].addend);
    try std.testing.expectEqualStrings("__g0", object.relocations.items[1].symbol);
    try std.testing.expectEqual(.addr64, object.relocations.items[1].kind);
    try std.testing.expectEqual(0, object.relocations.items[1].addend);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
}

test "readObject reads a PE/COFF object (sections, symbols, relocations)" {
    const gpa = std.testing.allocator;
    const obj_pe = @import("obj_pe.zig");

    const text_bytes = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 }; // mov rax, rdi; ret
    const data_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0 };

    // COFF section numbers are 1-based: .text=1, .data=2, .bss=3, 0=undefined.
    const symbols = &.{
        obj_pe.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_pe.Symbol{ .name = "__g0", .section_idx = 2, .value = 0, .size = 6,
            .binding = .global, .is_func = false },
        obj_pe.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };

    const relocs = &.{
        obj_pe.Reloc{ .section_idx = 1, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 },
        obj_pe.Reloc{ .section_idx = 2, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 },
    };

    const input = obj_pe.ObjectInput{
        .text = &text_bytes,
        .data = &data_bytes,
        .bss_size = 0,
        .symbols = symbols,
        .relocs = relocs,
    };

    var w = obj_pe.Writer.init(gpa);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer gpa.free(bytes);

    const path = "ferro_read_coff_test.obj";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    const io = std.testing.io;
    var object = try readObject(io, gpa, path);
    defer object.deinit(gpa);

    try std.testing.expectEqual(ObjectFormat.pe_coff, object.format);

    // Sections: .text, .data, .bss
    try std.testing.expectEqual(3, object.sections.items.len);
    try std.testing.expectEqualStrings(".text", object.sections.items[0].name);
    try std.testing.expectEqualSlices(u8, object.sections.items[0].content, &text_bytes);
    try std.testing.expectEqualStrings(".data", object.sections.items[1].name);
    try std.testing.expectEqualSlices(u8, object.sections.items[1].content, &data_bytes);
    try std.testing.expectEqualStrings(".bss", object.sections.items[2].name);
    try std.testing.expectEqual(0, object.sections.items[2].content.len);

    // Find the input symbols (section symbols come first in COFF).
    var main_idx: ?usize = null;
    var g0_idx: ?usize = null;
    var puts_idx: ?usize = null;
    var si: usize = 0;
    while (si < object.symbols.items.len) : (si += 1) {
        if (std.mem.eql(u8, object.symbols.items[si].name, "_main")) main_idx = si;
        if (std.mem.eql(u8, object.symbols.items[si].name, "__g0")) g0_idx = si;
        if (std.mem.eql(u8, object.symbols.items[si].name, "puts")) puts_idx = si;
    }
    try std.testing.expect(main_idx != null);
    try std.testing.expect(g0_idx != null);
    try std.testing.expect(puts_idx != null);

    try std.testing.expectEqualStrings("_main", object.symbols.items[main_idx.?].name);
    try std.testing.expectEqualStrings(".text", object.symbols.items[main_idx.?].section.?);
    try std.testing.expectEqualStrings("__g0", object.symbols.items[g0_idx.?].name);
    try std.testing.expectEqualStrings(".data", object.symbols.items[g0_idx.?].section.?);
    try std.testing.expectEqualStrings("puts", object.symbols.items[puts_idx.?].name);
    try std.testing.expectEqual(null, object.symbols.items[puts_idx.?].section);

    // PE/COFF addends are implicit at the relocation site; for PC32 the
    // implicit addend is -4 (the displacement is relative to the next
    // instruction, after the 4-byte placeholder).
    try std.testing.expectEqual(2, object.relocations.items.len);
    try std.testing.expectEqualStrings("puts", object.relocations.items[0].symbol);
    try std.testing.expectEqual(.pc32, object.relocations.items[0].kind);
    try std.testing.expectEqual(-4, object.relocations.items[0].addend);
    try std.testing.expectEqualStrings("__g0", object.relocations.items[1].symbol);
    try std.testing.expectEqual(.addr64, object.relocations.items[1].kind);
    try std.testing.expectEqual(0, object.relocations.items[1].addend);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
}

test "readObject reports ObjectReadFailed for a non-ELF/non-COFF file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const path = "ferro_read_bad_test.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &[_]u8{ 0x00, 0x01, 0x02, 0x03 } });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    if (readObject(io, gpa, path)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.ObjectReadFailed, err);
    }
}

test "resolveSymbols resolves an undefined program symbol against the runtime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main defined in .text, puts undefined.
    const prog_text = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 };
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_resolve_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts defined in .text (section 1).
    const rt_text = [_]u8{ 0x90, 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 2,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_resolve_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    var program = try readObject(io, gpa, prog_path);
    defer program.deinit(gpa);
    var runtime = try readObject(io, gpa, rt_path);
    defer runtime.deinit(gpa);

    var resolved = try resolveSymbols(&program, &runtime, "_main", gpa);
    defer resolved.deinit(gpa);

    try std.testing.expectEqual(0, resolved.undefined.items.len);
    if (resolved.resolved.get("puts")) |addr| {
        try std.testing.expectEqualStrings(".text", addr.section);
        try std.testing.expectEqual(0, addr.value);
    } else {
        try std.testing.expect(false);
    }
}

test "resolveSymbols reports UndefinedSymbol when the runtime does not define it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main defined, nosuch_symbol undefined.
    const prog_text = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 };
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "nosuch_symbol", .section_idx = obj_elf.ShnUndef, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_resolve_missing_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: does not define nosuch_symbol.
    const rt_text = [_]u8{ 0x90, 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "other", .section_idx = 0, .value = 0, .size = 2,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_resolve_missing_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    var program = try readObject(io, gpa, prog_path);
    defer program.deinit(gpa);
    var runtime = try readObject(io, gpa, rt_path);
    defer runtime.deinit(gpa);

    if (resolveSymbols(&program, &runtime, "_main", gpa)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.UndefinedSymbol, err);
    }
}

test "applyRelocations merges sections and applies PC32 + ADDR64 relocations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main in .text calls `puts` (extern, PC32 reloc at offset 0)
    // and references string literal `__g0` (ADDR64 reloc at data offset 0).
    // `__g0` is defined in the program object; `puts` is undefined here and
    // resolved against the runtime archive.
    const prog_text = [_]u8{ 0x48, 0x89, 0xf8, 0xc3 }; // mov rax, rdi; ret
    const prog_data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }; // 8-byte placeholder for __g0 address
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 4,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "__g0", .section_idx = 2, .value = 0, .size = 8,
            .binding = .global, .is_func = false },
        obj_elf.Symbol{ .name = "puts", .section_idx = obj_elf.ShnUndef, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_relocs = &.{
        obj_elf.Reloc{ .section_idx = 1, .offset = 0, .symbol = "puts", .kind = .pc32, .addend = -4 },
        obj_elf.Reloc{ .section_idx = 2, .offset = 0, .symbol = "__g0", .kind = .addr64, .addend = 0 },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = prog_relocs,
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_apply_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts defined at .text offset 0.
    const rt_text = [_]u8{ 0x90, 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 2,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_apply_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    var program = try readObject(io, gpa, prog_path);
    defer program.deinit(gpa);
    var runtime = try readObject(io, gpa, rt_path);
    defer runtime.deinit(gpa);

    var resolved = try resolveSymbols(&program, &runtime, "_main", gpa);
    defer resolved.deinit(gpa);

    var image = try applyRelocations(&program, &runtime, &resolved, gpa, .linux_x86_64);
    defer image.deinit(gpa);

    // Merged layout: .text = prog(4) + rt(2) = 6 bytes; .data = prog(8) + rt(0) = 8 bytes.
    // data_base = 6.
    try std.testing.expectEqual(6, image.text.len);
    try std.testing.expectEqual(8, image.data.len);

    // puts is runtime .text offset 0 => merged address 4 (prog_text_size). call site is .text offset 0.
    // PC32: S(4) + A(-4) - P(0) = 0 => disp32 = 0.
    try std.testing.expectEqualSlices(u8, image.text[0..4], &[_]u8{ 0x00, 0x00, 0x00, 0x00 });

    // __g0 ADDR64: S(data_base(6) + 0) + A(0) = 6 at .data offset 0 (little-endian u64).
    try std.testing.expectEqualSlices(u8, image.data[0..8], &[_]u8{ 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });

    // __g0 symbol resolves to merged address 6 in .data.
    if (image.symbols.get("__g0")) |addr| {
        try std.testing.expectEqualStrings(".data", addr.section);
        try std.testing.expectEqual(6, addr.value);
    } else {
        try std.testing.expect(false);
    }
}

test "writeExecutableElf produces an ELF executable whose _start calls _main" {
    const gpa = std.testing.allocator;

    // Merged image: _main at relative address 42, 2 bytes of program .text.
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    try symbols.put("_main", .{ .section = ".text", .value = 42 });

    var prog_text = [_]u8{ 0x90, 0x90 };
    var prog_data = [_]u8{};
    var image = MergedImage{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = symbols,
        .import_thunks = .empty,
        .import_desc_addr = 0,
        .import_desc_size = 0,
    };

    const buf = try writeExecutableElf(&image, 42, gpa);
    defer gpa.free(buf);

    // ELF header: ET_EXEC executable, x86-64.
    try std.testing.expectEqualSlices(u8, buf[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(2, readU16(buf, 16));      // e_type = ET_EXEC
    try std.testing.expectEqual(62, readU16(buf, 18));     // e_machine = EM_X86_64
    // e_entry = vaddr of _start = 0x400000 + start_offset(2) = 0x400002.
    try std.testing.expectEqual(0x400002, readU64(buf, 24));

    // Two PT_LOAD program headers at offset 64.
    try std.testing.expectEqual(1, readU32(buf, 64 + 0));  // p_type = PT_LOAD (.text)
    try std.testing.expectEqual(1, readU32(buf, 64 + 56)); // p_type = PT_LOAD (.data)

    // .text content at file offset 64 + 2*56 = 176, followed by the _start stub.
    const text_file_off: u64 = 64 + 2 * 56;
    try std.testing.expectEqualSlices(u8, buf[text_file_off..text_file_off + 2], &[_]u8{ 0x90, 0x90 });

    const stub_off = text_file_off + 2;
    try std.testing.expectEqual(0xe8, buf[stub_off]); // E8 = call rel32
    // disp = main_addr(42) - start_offset(2) - 5 = 35 = 0x23 (little-endian).
    try std.testing.expectEqualSlices(u8, buf[stub_off + 1..stub_off + 5], &[_]u8{ 0x23, 0x00, 0x00, 0x00 });
    // mov edi,eax; mov eax,60; syscall
    try std.testing.expectEqualSlices(
        u8,
        buf[stub_off + 5..stub_off + 14],
        &[_]u8{ 0x89, 0xc7, 0xb8, 0x3c, 0x00, 0x00, 0x00, 0x0f, 0x05 },
    );
}

test "writeExecutable reports UndefinedSymbol when entry symbol is absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    var prog_text = [_]u8{ 0x90 };
    var prog_data = [_]u8{};
    var image = MergedImage{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = symbols,
        .import_thunks = .empty,
        .import_desc_addr = 0,
        .import_desc_size = 0,
    };
    const opts = defaultLinkOptions(.linux_x86_64);
    if (writeExecutable(&image, "no-such-entry.exe", opts, gpa, io)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkError.UndefinedSymbol, err);
    }
}

test "linkObject writes an ELF executable whose entry _start calls _main" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_elf = @import("obj_elf.zig");

    // Program object: _main (ret) in .text, puts undefined.
    var prog_text = [_]u8{ 0xc3 };
    const prog_symbols = &.{
        obj_elf.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = true },
        obj_elf.Symbol{ .name = "puts", .section_idx = obj_elf.ShnUndef, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_elf.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var prog_w = obj_elf.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_entry_prog.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts (nop) defined in .text.
    const rt_text = [_]u8{ 0x90 };
    const rt_symbols = &.{
        obj_elf.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_elf.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_elf.Reloc{},
    };
    var rt_w = obj_elf.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_entry_rt.o";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    const exe_path = "ferro_entry.exe";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const opts = defaultLinkOptions(.linux_x86_64);
    try linkObject(io, gpa, prog_path, rt_path, exe_path, opts);

    const exe_bytes = try std.Io.Dir.cwd().readFileAlloc(io, exe_path, gpa, .unlimited);
    defer gpa.free(exe_bytes);

    try std.testing.expectEqualSlices(u8, exe_bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(2, readU16(exe_bytes, 16)); // ET_EXEC
    // e_entry = 0x400000 + start_offset. merged .text = prog(1) + rt(1) = 2, _start at offset 2.
    try std.testing.expectEqual(0x400002, readU64(exe_bytes, 24));

    const text_file_off: u64 = 64 + 2 * 56;
    const stub_off = text_file_off + 2; // after 2 bytes of merged .text
    try std.testing.expectEqual(0xe8, exe_bytes[stub_off]); // call rel32
    // disp = main_addr(0) - start_offset(2) - 5 = -7 = 0xfffffff9 (little-endian: f9 ff ff ff).
    try std.testing.expectEqualSlices(u8, exe_bytes[stub_off + 1..stub_off + 5], &[_]u8{ 0xf9, 0xff, 0xff, 0xff });
}

test "linkObject writes a PE executable whose entry main calls _main" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const obj_pe = @import("obj_pe.zig");

    // Program object: _main (ret) in .text, puts undefined.
    var prog_text = [_]u8{ 0xc3 };
    const prog_symbols = &.{
        obj_pe.Symbol{ .name = "_main", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = true },
        obj_pe.Symbol{ .name = "puts", .section_idx = 0, .value = 0, .size = 0,
            .binding = .global, .is_func = false },
    };
    const prog_input = obj_pe.ObjectInput{
        .text = &prog_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = prog_symbols,
        .relocs = &[_]obj_pe.Reloc{},
    };
    var prog_w = obj_pe.Writer.init(gpa);
    defer prog_w.deinit();
    const prog_bytes = try prog_w.writeObject(prog_input);
    defer gpa.free(prog_bytes);
    const prog_path = "ferro_link_pe_prog.obj";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prog_path, .data = prog_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, prog_path) catch {};

    // Runtime object: puts (nop) defined in .text.
    const rt_text = [_]u8{ 0x90 };
    const rt_symbols = &.{
        obj_pe.Symbol{ .name = "puts", .section_idx = 1, .value = 0, .size = 1,
            .binding = .global, .is_func = false },
    };
    const rt_input = obj_pe.ObjectInput{
        .text = &rt_text,
        .data = &[_]u8{},
        .bss_size = 0,
        .symbols = rt_symbols,
        .relocs = &[_]obj_pe.Reloc{},
    };
    var rt_w = obj_pe.Writer.init(gpa);
    defer rt_w.deinit();
    const rt_bytes = try rt_w.writeObject(rt_input);
    defer gpa.free(rt_bytes);
    const rt_path = "ferro_link_pe_rt.obj";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rt_path, .data = rt_bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rt_path) catch {};

    const exe_path = "ferro_link_pe.exe";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const opts = defaultLinkOptions(.windows_x86_64);
    try linkObject(io, gpa, prog_path, rt_path, exe_path, opts);

    const exe_bytes = try std.Io.Dir.cwd().readFileAlloc(io, exe_path, gpa, .unlimited);
    defer gpa.free(exe_bytes);

    // DOS header + e_lfanew pointing at the PE signature.
    try std.testing.expectEqualSlices(u8, exe_bytes[0..2], &[_]u8{ 'M', 'Z' });
    try std.testing.expectEqual(64, readU32(exe_bytes, 60));

    // PE signature + COFF file header.
    try std.testing.expectEqualSlices(u8, exe_bytes[64..68], &[_]u8{ 'P', 'E', 0, 0 });
    try std.testing.expectEqual(0x8664, readU16(exe_bytes, 68)); // machine = AMD64

    // Optional header (PE32+): magic 0x20b at offset 88.
    try std.testing.expectEqual(0x20b, readU16(exe_bytes, 88)); // magic = PE32+
    // AddressOfEntryPoint at optional header + 16 = 104.
    // AddressOfEntryPoint is an RVA = stub_rel_addr(0x1002).
    try std.testing.expectEqual(0x1002, readU32(exe_bytes, 104));

    // .text raw data at file offset size_of_headers = alignUp(448, 512) = 512.
    // merged .text = prog(1 byte ret) + rt(1 byte nop) = 2 bytes.
    const text_file_off: u64 = 512;
    try std.testing.expectEqual(0xc3, exe_bytes[text_file_off]); // program byte (ret)
    try std.testing.expectEqual(0x90, exe_bytes[text_file_off + 1]); // runtime byte (nop)
    // main stub right after: E8 disp32 + C3 ret.
    const stub_off = text_file_off + 2;
    try std.testing.expectEqual(0xe8, exe_bytes[stub_off]); // E8 = call rel32
    // disp = main_rel_addr(0) - stub_rel_addr(2) - 5 = -7 = 0xfffffff9 (little-endian: f9 ff ff ff).
    // (Both addresses are VA-relative with the 0x1000 .text base, which cancels.)
    try std.testing.expectEqualSlices(u8, exe_bytes[stub_off + 1..stub_off + 5], &[_]u8{ 0xf9, 0xff, 0xff, 0xff });
    try std.testing.expectEqual(0xc3, exe_bytes[stub_off + 5]); // C3 = ret
}

test "writeExecutablePe produces a PE executable whose main calls _main" {
    const gpa = std.testing.allocator;

    // Merged image: _main at relative address 10, 1 byte of program .text.
    var symbols = std.StringHashMap(ResolvedSymbol).init(gpa);
    defer symbols.deinit();
    try symbols.put("_main", .{ .section = ".text", .value = 10 });

    var prog_text = [_]u8{ 0x90 };
    var prog_data = [_]u8{};
    var image = MergedImage{
        .text = &prog_text,
        .data = &prog_data,
        .bss_size = 0,
        .symbols = symbols,
        .import_thunks = .empty,
        .import_desc_addr = 0,
        .import_desc_size = 0,
    };

    const buf = try writeExecutablePe(&image, 10, .console, gpa);
    defer gpa.free(buf);

    // DOS header + e_lfanew pointing at the PE signature.
    try std.testing.expectEqualSlices(u8, buf[0..2], &[_]u8{ 'M', 'Z' });
    try std.testing.expectEqual(64, readU32(buf, 60)); // e_lfanew = offset to "PE\0\0"

    // PE signature + COFF file header.
    try std.testing.expectEqualSlices(u8, buf[64..68], &[_]u8{ 'P', 'E', 0, 0 });
    try std.testing.expectEqual(0x8664, readU16(buf, 68)); // machine = AMD64

    // Optional header (PE32+): magic 0x20b at offset 88.
    try std.testing.expectEqual(0x20b, readU16(buf, 88)); // magic = PE32+
    // AddressOfEntryPoint at optional header + 16 = 104.
    // AddressOfEntryPoint is an RVA = stub_rel_addr(0x1001).
    try std.testing.expectEqual(0x1001, readU32(buf, 104));

    // .text raw data at file offset size_of_headers = alignUp(448, 512) = 512.
    const text_file_off: u64 = 512;
    try std.testing.expectEqual(0x90, buf[text_file_off]); // program byte
    // main stub right after: E8 disp32 + C3 ret.
    const stub_off = text_file_off + 1;
    try std.testing.expectEqual(0xe8, buf[stub_off]); // E8 = call rel32
    // disp = main_rel_addr(10) - stub_rel_addr(1) - 5 = 4 = 0x00000004 (LE: 04 00 00 00).
    // (Both addresses are VA-relative with the 0x1000 .text base, which cancels.)
    try std.testing.expectEqualSlices(u8, buf[stub_off + 1..stub_off + 5], &[_]u8{ 0x04, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(0xc3, buf[stub_off + 5]); // C3 = ret
}

