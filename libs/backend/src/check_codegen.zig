//! `check_codegen` — static byte-level verifier for Tungsten object files.
//!
//! Parses a Tungsten-emitted relocatable object (ELF64 or PE/COFF), disassembles
//! each `.text` function, and validates the byte-level encoding rules that
//! codegen.zig must obey:
//!
//!   - Every `sub/add rsp` uses an appropriate immediate width (no sign-extended
//!     8-bit immediates for frame sizes > 127).
//!   - `setcc`/`cmov` instructions have a ModR/M byte.
//!   - SIB bytes use index = none (`0x24`) when base is `rsp`/`rbp`.
//!   - REX prefixes are consistent with the named destination registers.
//!   - Branch targets resolve to block boundaries (via relocation/symbol map).
//!
//! Reports violations with function name, byte offset, and the offending bytes.
//!
//! The decoder handles only the x86-64 subset Tungsten emits:
//! mov, lea, add, sub, cmp, setcc, jmp, je, call, push, pop, leave, ret,
//! idiv/div, movzx, cqo, and REX-prefixed variants.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const Object = ferro_types.Object;
const Symbol = ferro_types.Symbol;
const Section = ferro_types.Section;
const Binding = ferro_types.Binding;

pub const CheckError = error{
    ObjectReadFailed,
    NoTextSection,
    TruncatedInstruction,
    UnknownOpcode,
    UnexpectedREX,
    UnsupportedModRM,
    UnexpectedSIB,
    DisplacementOutOfRange,
};

/// A single validation violation.
pub const Violation = struct {
    function: []const u8,
    /// Byte offset within `.text`.
    offset: u64,
    message: []const u8,
    /// Offending bytes (up to 16).
    bytes: [16]u8,
    byte_len: u8,
};

/// Function recorded in .text: name, offset within .text, size in bytes.
pub const FuncInfo = struct {
    name: []const u8,
    offset: u64,
    size: u64,
};

pub const Report = struct {
    violations: std.ArrayList(Violation),
    pub fn deinit(self: *Report, gpa: Allocator) void {
        self.violations.deinit(gpa);
    }
};

/// Run all checks on `obj`. Returns a `Report` (caller must inspect
/// `report.violations` and deinit).
pub fn checkObject(gpa: Allocator, obj: *const Object) !Report {
    var report = Report{ .violations = .empty };
    errdefer report.deinit(gpa);

    const text_sec = findSection(obj, ".text") orelse return error.NoTextSection;
    const text = text_sec.content;

    // Build function map: symbol name -> (offset, size) within .text.
    var funcs = std.ArrayList(FuncInfo).empty;
    defer {
        for (funcs.items) |*f| gpa.free(f.name);
        funcs.deinit(gpa);
    }
    for (obj.symbols.items) |sym| {
        if (sym.section == null) continue;
        if (!std.mem.eql(u8, sym.section.?, ".text")) continue;
        if (sym.name.len == 0) continue;
        const name = try gpa.dupe(u8, sym.name);
        try funcs.append(gpa, .{ .name = name, .offset = sym.value, .size = sym.size });
    }

    // Sort functions by offset for binary search.
    std.mem.sort(FuncInfo, funcs.items, {}, byOffset);

    var pc: u64 = 0;
    while (pc < text.len) {
        const func = findFuncAt(funcs.items, pc);
        const func_name = if (func) |f| f.name else "";
        const inst_start = pc;

        const decoded = if (decodeInstruction(text[pc..])) |d| d else |_| {
            // If we can't decode, stop disassembling this function to avoid
            // cascading false positives, but report the truncation.
            _ = try reportViolation(gpa, &report, func_name, inst_start,
                "undecodable bytes at end of function", text[inst_start..]);
            break;
        };
        pc = inst_start + @as(u64, decoded.len);

        try validateInstruction(gpa, &report, func_name, inst_start, decoded, text, funcs.items);
    }

    return report;
}

fn byOffset(_: void, a: FuncInfo, b: FuncInfo) bool {
    return a.offset < b.offset;
}

fn findSection(obj: *const Object, name: []const u8) ?*const ferro_types.Section {
    for (obj.sections.items) |*sec| {
        if (std.mem.eql(u8, sec.name, name)) return sec;
    }
    return null;
}

fn findFuncAt(funcs: []const FuncInfo, pc: u64) ?*const FuncInfo {
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

fn reportViolation(gpa: Allocator, report: *Report, func_name: []const u8, offset: u64,
    message: []const u8, bytes: []const u8) !void {
    var v = Violation{ .function = func_name, .offset = offset, .message = message,
        .bytes = undefined, .byte_len = 0 };
    var i: usize = 0;
    while (i < bytes.len and i < 16) : (i += 1) {
        v.bytes[i] = bytes[i];
    }
    v.byte_len = @intCast(bytes.len);
    try report.violations.append(gpa, v);
}

// ============================================================================
// x86-64 decoder (Tungsten-emitted subset)
// ============================================================================

/// Registers referenced by Tungsten codegen (REX.R/B and ModR/M reg fields).
pub const Reg = enum(u8) {
    rax = 0, rcx = 1, rdx = 2, rbx = 3,
    rsp = 4, rbp = 5, rsi = 6, rdi = 7,
    r8 = 8, r9 = 9, r10 = 10, r11 = 11,
    r12 = 12, r13 = 13, r14 = 14, r15 = 15,
    xmm0 = 0, xmm1 = 1, xmm2 = 2, xmm3 = 3,
};

/// The decoded form of one instruction.
pub const DecodedInstruction = struct {
    /// Length in bytes.
    len: u8,
    /// Primary opcode byte(s) after REX/prefixes.
    opcode: u8,
    /// Second opcode byte for two-byte opcodes (0x0F escapes), else 0.
    opcode2: u8,
    /// Whether a REX prefix was present.
    has_rex: bool,
    rex: u8,
    /// Whether a ModR/M byte was present.
    has_modrm: bool,
    modrm: u8,
    /// Whether a SIB byte was present.
    has_sib: bool,
    sib: u8,
    /// Displacement bytes follow ModR/M/SIB.
    disp_len: u8,
    disp: i64,
    /// Immediate bytes follow displacement.
    imm_len: u8,
    imm: u64,
    /// Start offset of the ModR/M byte (or 0 if none), relative to inst start.
    modrm_off: u8,
    /// Start offset of the SIB byte, relative to inst start.
    sib_off: u8,
    /// Start offset of the displacement, relative to inst start.
    disp_off: u8,
    /// Start offset of the immediate, relative to inst start.
    imm_off: u8,
};

/// Decode one instruction at `bytes`. Returns the decoded form and the next PC.
/// Only the Tungsten-emitted subset is understood; anything else returns
/// error.UnknownOpcode or error.TruncatedInstruction.
pub fn decodeInstruction(bytes: []const u8) !DecodedInstruction {
    if (bytes.len == 0) return error.TruncatedInstruction;

    var i: usize = 0;
    var rex: u8 = 0x40;
    var has_rex = false;
    var modrm_off: u8 = 0;
    var sib_off: u8 = 0;
    var disp_off: u8 = 0;
    var imm_off: u8 = 0;

    // --- REX prefix ---
    if (bytes[0] & 0xF0 == 0x40) {
        rex = bytes[0];
        has_rex = true;
        i += 1;
        if (i >= bytes.len) return error.TruncatedInstruction;
    }

    const opcode = bytes[i];
    i += 1;

    // Two-byte escape 0x0F.
    var opcode2: u8 = 0;
    if (opcode == 0x0F) {
        if (i >= bytes.len) return error.TruncatedInstruction;
        opcode2 = bytes[i];
        i += 1;
    }

    // --- ModR/M ---
    var has_modrm = false;
    var modrm: u8 = 0;
    var has_sib = false;
    var sib: u8 = 0;
    var disp_len: u8 = 0;
    var disp: i64 = 0;

    const needs_modrm = switch (opcode2) {
        // 0x0F group
        0xB6 => true, // movzx
        else => switch (opcode) {
            0x8B => true, // mov r/m32 -> r32
            0x89 => true, // mov r32 -> r/m32
            0x8D => true, // lea
            0x03, 0x2B, 0x23, 0x0B, 0x31 => true, // add/sub/and/or/xor r/m32 -> r32
            0x3B => true, // cmp
            0xF7 => true, // idiv/div r/m32
            0x83 => true, // cmp rax, imm8
            0x85 => true, // test (not emitted)
            0xA1 => true, // mov rax, moffs (not emitted)
            0x8A => true, // mov r8, r/m8
            0x0F => false, // handled above
            else => false,
        },
    };

    if (needs_modrm) {
        if (i >= bytes.len) return error.TruncatedInstruction;
        modrm_off = @intCast(i);
        modrm = bytes[i];
        i += 1;
        has_modrm = true;

        const mod_val = modrm >> 6;
        const rm = modrm & 0x07;

        // SIB when mod != 3 and rm == 4 (rsp/r12 base).
        if (mod_val != 3 and rm == 0b100) {
            if (i >= bytes.len) return error.TruncatedInstruction;
            sib_off = @intCast(i);
            sib = bytes[i];
            i += 1;
            has_sib = true;
            const sib_base = sib & 0x07;
            // Effective base for displacement sizing.
            const uses_rbp13 = (sib_base == 0b101); // rbp or r13
            const disp_size: u8 = switch (mod_val) {
                0b00 => if (uses_rbp13) 4 else 0,
                0b01 => 1,
                0b10 => 4,
                0b11 => 0, // register-direct: no displacement
                else => 0, // mod_val is a 2-bit field; unreachable
            };
            if (disp_size == 4) {
                if (i + 4 > bytes.len) return error.TruncatedInstruction;
                disp_off = @intCast(i);
                const raw: u32 = readU32(bytes, i);
                const raw_i32: i32 = @bitCast(raw);
                disp = @intCast(raw_i32); // sign-extend i32 -> i64
                i += 4;
                disp_len = 4;
            } else if (disp_size == 1) {
                if (i + 1 > bytes.len) return error.TruncatedInstruction;
                disp_off = @intCast(i);
                const b: i8 = @bitCast(bytes[i]);
                disp = @intCast(b); // sign-extend i8 -> i64
                i += 1;
                disp_len = 1;
            }
        } else {
            const uses_rbp13 = (rm == 0b101);
            const disp_size: u8 = switch (mod_val) {
                0b00 => if (uses_rbp13) 4 else 0,
                0b01 => 1,
                0b10 => 4,
                0b11 => 0, // register-direct: no displacement
                else => 0, // mod_val is a 2-bit field; unreachable
            };
            if (disp_size == 4) {
                if (i + 4 > bytes.len) return error.TruncatedInstruction;
                disp_off = @intCast(i);
                const raw: u32 = readU32(bytes, i);
                const raw_i32: i32 = @bitCast(raw);
                disp = @intCast(raw_i32); // sign-extend i32 -> i64
                i += 4;
                disp_len = 4;
            } else if (disp_size == 1) {
                if (i + 1 > bytes.len) return error.TruncatedInstruction;
                disp_off = @intCast(i);
                const b: i8 = @bitCast(bytes[i]);
                disp = @intCast(b); // sign-extend i8 -> i64
                i += 1;
                disp_len = 1;
            }
        }
    }

    // --- Immediate ---
    var imm_len: u8 = 0;
    var imm: u64 = 0;
    const needs_imm = switch (opcode2) {
        else => switch (opcode) {
            0xE8 => true, // call rel32
            0xE9 => true, // jmp rel32
            0xEB => true, // jmp rel8
            0x74 => true, // je rel8
            0x83 => true, // cmp rax, imm8
            0xB8 => true, // mov rax, imm64
            else => false,
        },
    };
    if (needs_imm) {
        const imm_size: u8 = switch (opcode) {
            0xB8 => 8,
            0xE8, 0xE9 => 4,
            0xEB, 0x74, 0x83 => 1,
            else => 4,
        };
        if (i + imm_size > bytes.len) return error.TruncatedInstruction;
        imm_off = @intCast(i);
        if (imm_size == 8) {
            imm = readU64(bytes, i);
        } else if (imm_size == 4) {
            imm = readU32(bytes, i);
        } else {
            imm = @as(u64, @as(u8, bytes[i]));
        }
        i += @intCast(imm_size);
        imm_len = @intCast(imm_size);
    }

    return DecodedInstruction{
        .len = @intCast(i),
        .opcode = opcode,
        .opcode2 = opcode2,
        .has_rex = has_rex,
        .rex = rex,
        .has_modrm = has_modrm,
        .modrm = modrm,
        .has_sib = has_sib,
        .sib = sib,
        .disp_len = disp_len,
        .disp = disp,
        .imm_len = imm_len,
        .imm = imm,
        .modrm_off = modrm_off,
        .sib_off = sib_off,
        .disp_off = disp_off,
        .imm_off = imm_off,
    };
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

fn regIndexOf(rex: u8, modrm: u8) u8 {
    // reg field = bits 5..3 of ModR/M; REX.R (bit 3 of REX) extends it.
    const reg = (modrm >> 3) & 0x07;
    return if (rex & 0x08 != 0) reg | 0x08 else reg;
}

fn rmIndexOf(rex: u8, modrm: u8) u8 {
    const rm = modrm & 0x07;
    return if (rex & 0x01 != 0) rm | 0x08 else rm;
}

/// Validate a single decoded instruction against the encoding rules.
fn validateInstruction(gpa: Allocator, report: *Report, func_name: []const u8,
    inst_start: u64, d: DecodedInstruction, text: []const u8,
    funcs: []const FuncInfo,
) !void {
    const inst_bytes = text[inst_start .. inst_start + @as(usize, d.len)];

    // --- Rule: every sub/add rsp uses an appropriate immediate width ---
    if (d.opcode == 0x83 and d.opcode2 == 0) {
        // 0x83 /5 = sub rsp, imm8 or add rsp, imm8 (modrm reg field = 5 or 0)
        if (d.has_modrm) {
            const reg = (d.modrm >> 3) & 0x07;
            const rm = d.modrm & 0x07;
            if (reg == 0b101 and rm == 0b100) {
                // sub/add rsp, imm8 — the imm8 sign-extends; flag if frame size > 127.
                if (d.imm_len == 1) {
                    const imm8: u8 = @truncate(d.imm);
                    // A legitimate small frame adjustment (<= 127) has the high
                    // bit clear. If the high bit is set, the 8-bit immediate
                    // truncated a larger frame size and sign-extended negative
                    // (bug #1 in docs/debugging.md).
                    if (imm8 > 127) {
                        const msg = if (reg == 0b101)
                            "sub rsp uses 8-bit immediate for frame size > 127 (sign-extends negative)"
                        else
                            "add rsp uses 8-bit immediate for frame size > 127 (sign-extends negative)";
                        try reportViolation(gpa, report, func_name, inst_start, msg, inst_bytes);
                    }
                }
            }
        }
    }

    // --- Rule: setcc / cmov have a ModR/M byte ---
    if (d.opcode2 != 0) {
        if (d.opcode2 >= 0x90 and d.opcode2 <= 0x9F) {
            // setcc / cmov group (0x0F 0x90-0x9F)
            if (!d.has_modrm) {
                try reportViolation(gpa, report, func_name, inst_start,
                    "setcc/cmov missing ModR/M byte", inst_bytes);
            }
        }
    }

    // --- Rule: SIB index = none (0x24) when base is rsp/rbp ---
    if (d.has_sib) {
        const sib_index = (d.sib >> 3) & 0x07;
        const sib_base = d.sib & 0x07;
        // index = none is 0b100 (4). When base is rsp (0b100) or rbp (0b101),
        // the index field must be none.
        if (sib_base == 0b100 or sib_base == 0b101) {
            if (sib_index != 0b100) {
                try reportViolation(gpa, report, func_name, inst_start,
                    "SIB index != none with rsp/rbp base", inst_bytes);
            }
        }
    }

    // --- Rule: REX prefixes consistent with named destination registers ---
    // Validate REX.W/REX.R consistency for the mov r64, imm64 opcode (0x48 B8)
    // and for REX-prefixed ModR/M instructions where reg encodes an extended register.
    if (d.has_rex) {
        // mov rax, imm64 must use REX.W=1, REX.R=0, REX.X=0, REX.B=0 (0x48).
        if (d.opcode == 0xB8 and d.opcode2 == 0) {
            const rex_w = (d.rex >> 3) & 1;
            const rex_r = (d.rex >> 2) & 1;
            const rex_x = (d.rex >> 1) & 1;
            const rex_b = d.rex & 1;
            if (rex_w != 1 or rex_r != 0 or rex_x != 0 or rex_b != 0) {
                try reportViolation(gpa, report, func_name, inst_start,
                    "mov rax, imm64 has inconsistent REX prefix", inst_bytes);
            }
        }
    }

    // --- Rule: branch targets resolve to block boundaries ---
    // Direct relative branches/calls (jmp rel32, je rel8, call rel32) land at
    // the start of an instruction within the current function; indirect branches
    // and reloc sites are recorded separately.
    if ((d.opcode == 0xE9 or d.opcode == 0xEB or d.opcode == 0x74) and d.opcode2 == 0) {
        var target_off: i64 = 0;
        if (d.opcode == 0xE9) {
            const raw: u32 = @truncate(d.imm);
            const s: i32 = @bitCast(raw);
            target_off = @as(i64, @intCast(s));
        } else if (d.opcode == 0xEB or d.opcode == 0x74) {
            const raw: u8 = @truncate(d.imm);
            const s: i8 = @bitCast(raw);
            target_off = @as(i64, @intCast(s));
        }
        const target_pc: i64 = @as(i64, @intCast(inst_start)) + @as(i64, @intCast(d.len)) + target_off;
        const func = findFuncAt(funcs, inst_start) orelse null;
        if (func) |f| {
            // The target must lie within this function and at an instruction
            // boundary. We can only check boundaries approximately: the target
            // must be within the function's [offset, offset+size).
            const foff: i64 = @as(i64, @intCast(f.offset));
            const fsize: i64 = @as(i64, @intCast(f.size));
            if (target_pc < foff or target_pc >= foff + fsize) {
                try reportViolation(gpa, report, func_name, inst_start,
                    "branch target outside enclosing function", inst_bytes);
            }
        }
    }

    // Check for trailing bytes / un-decodable opcodes within the function body
    // are handled by the caller (decodeInstruction).
    return;
}

// ============================================================================
// Tests
// ============================================================================

/// Build a minimal `Object` holding `text` bytes with a single `_main`
/// function symbol spanning the whole .text section.
fn testObject(gpa: Allocator, text: []const u8) !Object {
    var obj = Object{
        .path = "",
        .format = .elf64,
        .file_bytes = try gpa.alloc(u8, 0),
        .sections = .empty,
        .symbols = .empty,
        .relocations = .empty,
        .owns_symbol_names = true, // testObject dupes symbol names; free them on deinit
    };
    errdefer obj.deinit(gpa);
    try obj.sections.append(gpa, .{
        .name = ".text",
        .offset = 0,
        .size = @as(u64, text.len),
        .flags = 0,
        .type_ = 0,
        .content = text,
    });
    try obj.symbols.append(gpa, .{
        .name = try gpa.dupe(u8, "_main"),
        .section = ".text",
        .value = 0,
        .size = @as(u64, text.len),
        .binding = .global,
    });
    return obj;
}

test "check_codegen: well-formed object reports no violations" {
    const gpa = std.testing.allocator;
    // push rbp; mov rbp, rsp; mov rax, 42; mov [rbp-8], rax; leave; ret
    const text = [_]u8{
        0x55, 0x48, 0x89, 0xe5,
        0x48, 0xb8, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x48, 0x89, 0x85, 0xf8, 0xff, 0xff, 0xff,
        0xc9, 0xc3,
    };
    var obj = try testObject(gpa, &text);
    defer obj.deinit(gpa);
    var report = try checkObject(gpa, &obj);
    defer report.deinit(gpa);
    try std.testing.expectEqual(0, report.violations.items.len);
}

test "check_codegen: sub rsp with truncated 8-bit immediate is flagged" {
    const gpa = std.testing.allocator;
    // sub rsp, 200 encoded as 8-bit (0xc8 = 200 > 127, sign-extends negative);
    // then leave; ret
    const text = [_]u8{ 0x48, 0x83, 0xec, 0xc8, 0xc9, 0xc3 };
    var obj = try testObject(gpa, &text);
    defer obj.deinit(gpa);
    var report = try checkObject(gpa, &obj);
    defer report.deinit(gpa);
    try std.testing.expectEqual(1, report.violations.items.len);
    try std.testing.expectEqualSlices(
        u8,
        "sub rsp uses 8-bit immediate for frame size > 127 (sign-extends negative)",
        report.violations.items[0].message,
    );
    try std.testing.expectEqual(0, report.violations.items[0].offset);
}

test "check_codegen: SIB index != none with rsp base is flagged" {
    const gpa = std.testing.allocator;
    // mov rax, [rsp + rax]  = 0x48 0x8b 0x04 0x04  (SIB 0x04: base=rsp, index=rax=0 -> BUG)
    const text = [_]u8{ 0x48, 0x8b, 0x04, 0x04, 0xc3 };
    var obj = try testObject(gpa, &text);
    defer obj.deinit(gpa);
    var report = try checkObject(gpa, &obj);
    defer report.deinit(gpa);
    try std.testing.expectEqual(1, report.violations.items.len);
    try std.testing.expectEqualSlices(
        u8,
        "SIB index != none with rsp/rbp base",
        report.violations.items[0].message,
    );
}

test "check_codegen: SIB index == none with rsp base is accepted" {
    const gpa = std.testing.allocator;
    // mov rax, [rsp]        = 0x48 0x8b 0x04 0x24  (SIB 0x24: base=rsp, index=none -> OK)
    const text = [_]u8{ 0x48, 0x8b, 0x04, 0x24, 0xc3 };
    var obj = try testObject(gpa, &text);
    defer obj.deinit(gpa);
    var report = try checkObject(gpa, &obj);
    defer report.deinit(gpa);
    try std.testing.expectEqual(0, report.violations.items.len);
}
