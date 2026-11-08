//! `ore disasm` — Tungsten-aware disassembler CLI front-end.
//!
//! Disassembles a Wolframite object file (`.o` / `.obj`) or executable,
//! printing each function with its symbol name, byte range, raw instruction
//! bytes, and inline relocation annotations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Tungsten = @import("Tungsten");
const disasm_mod = Tungsten.disasm;
const ferro_reader = Tungsten.ferro_reader;

/// `ore disasm <file>` — disassemble a Tungsten object file or executable.
pub fn cmdDisasm(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    if (args.len == 0) {
        reportErr(io, "error: disasm requires an object file\n", .{});
        reportErr(io, "usage: ore disasm <file.o>\n", .{});
        return 2;
    }
    if (args.len > 1) {
        reportErr(io, "error: unexpected argument '{s}'\n", .{args[1]});
        return 2;
    }
    const path = args[0];

    var obj = try ferro_reader.readObject(io, gpa, path);
    defer obj.deinit(gpa);

    var report = try disasm_mod.disassembleObject(gpa, &obj);
    defer report.deinit(gpa);

    if (report.funcs.items.len == 0) {
        printOut(io, "disasm: {s}: no functions found\n", .{path});
        return 0;
    }

    for (report.funcs.items) |f| {
        printOut(io, "{s} (+{d} bytes):\n", .{ f.name, f.size });
        for (f.lines.items) |l| {
            var hex: [32]u8 = undefined;
            var hi: usize = 0;
            while (hi < l.bytes.len and hi < 16) : (hi += 1) {
                const b = l.bytes[hi];
                const hi_nib = b >> 4;
                const lo_nib = b & 0x0f;
                hex[hi * 2] = if (hi_nib < 10) '0' + @as(u8, hi_nib) else 'a' + @as(u8, hi_nib - 10);
                hex[hi * 2 + 1] = if (lo_nib < 10) '0' + @as(u8, lo_nib) else 'a' + @as(u8, lo_nib - 10);
            }
            printOut(io, "  {x} {s}  {s}", .{ l.offset, hex[0..hi * 2], l.text });
            if (l.annotation.len > 0) {
                printOut(io, "   ; {s}", .{l.annotation});
            }
            printOut(io, "\n", .{});
        }
    }

    return 0;
}

fn printOut(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn reportErr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}
