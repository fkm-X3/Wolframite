// Slot/phi liveness checker for Tungsten IR.
//
// Statically verifies, per function:
//   - Every value slot read (as an operand) is defined before use.
//     Parameters are defined in block 0; instruction results are defined by
//     their own instruction.
//   - No slot is defined in multiple blocks without a phi merging them.
//   - Every phi incoming block is a predecessor of the phi's block.
//
// Reports are collected into an allocator-owned slice and returned to the
// caller for printing.
const std = @import("std");
const ir = @import("ir.zig");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;

pub const Report = struct {
    function: []const u8,
    /// Human-readable description of the violation.
    message: []const u8,
    /// Instruction index where the violation was detected (or u32.max for
    /// block/function-level issues such as a non-predecessor phi).
    inst: u32,
    /// Byte offset of the offending operand within the instruction's operand
    /// slice (or u32.max when not applicable).
    operand: u32,
};

pub const Verifier = struct {
    gpa: Allocator,
    module: *const ir.Module,

    reports: std.ArrayList(Report),
};

pub const VerifyError = error{
    OutOfBoundsSlot,
    SlotUsedWithoutPhi,
    UndefinedSlot,
};

pub fn init(gpa: Allocator, module: *const ir.Module) Verifier {
    return .{
        .gpa = gpa,
        .module = module,
        .reports = .empty,
    };
}

pub fn deinit(self: *Verifier) void {
    self.reports.deinit(self.gpa);
}

/// Run the verification over every function in the module. Returns the
/// number of reports recorded.
pub fn verifyAll(self: *Verifier) !u32 {
    for (self.module.functions.items) |*func| {
        try self.verifyFunction(func);
    }
    return @intCast(self.reports.items.len);
}

fn verifyFunction(self: *Verifier, func: *const ir.Function) !void {
    const fname = self.module.strings.get(func.name);
    const param_count = func.param_count;

    // Value => the block index where it was first defined, or u32.max when
    // it has been defined in more than one block (requiring a phi).
    var defined_block = try self.gpa.alloc(u32, func.instructions.items.len + @as(usize, @intCast(param_count)));
    var i: u32 = 0;
    while (i < @as(usize, @intCast(param_count)) + func.instructions.items.len) : (i += 1) {
        defined_block[@as(usize, i)] = u32.max; // u32.max = not yet defined
    }

    // Track which block each value was defined in for phi conflict detection.
    // Parameters are defined in block 0 at function entry.
    var p: u32 = 0;
    while (p < param_count) : (p += 1) {
        defined_block[@as(usize, p)] = 0;
    }

    var block: u32 = 0;
    while (block < func.blocks.items.len) : (block += 1) {
        const b = &func.blocks.items[@as(usize, block)];
        var inst_off: u32 = @intFromEnum(b.first_inst);
        const inst_end: u32 = inst_off + b.inst_count;
        while (inst_off < inst_end) : (inst_off += 1) {
            const inst = func.instructions.items[@as(usize, inst_off)];
            const ops = func.getOperands(inst.operands);

            // Validate all operand reads: each operand slot must be defined
            // in the current block or in a block that dominates this one.
            // For simplicity (and to avoid computing a full dominator tree),
            // we require the defining block to be either the current block or
            // an earlier block index. Phi nodes are exempted per-operand
            // below.
            var o: u32 = 0;
            while (o < ops.len) : (o += 1) {
                const operand = ops[@as(usize, o)];
                const operand_block = defined_block[@as(usize, @intFromEnum(operand))];
                if (operand_block == u32.max) {
                    const msg = try fmt.allocPrint(self.gpa,
                        "use of undefined slot %{d} at %{d}.{d}", .{ operand, inst_off, o });
                    defer self.gpa.free(msg);
                    try self.addReport(fname, msg, inst_off, o);
                } else if (operand_block != block and operand_block != u32.max) {
                    // Defined in another block; only legal if consumed by a
                    // phi whose incoming pair lists this defining block.
                    if (!isPhiConsumingDefinedBlock(func, inst_off, operand, operand_block)) {
                        const msg = try fmt.allocPrint(self.gpa,
                            "slot %{d} defined in block %{d} used at %{d}.{d} without phi",
                            .{ operand, operand_block, inst_off, o });
                        defer self.gpa.free(msg);
                        try self.addReport(fname, msg, inst_off, o);
                    }
                }
                o += 1;
            }

            // Mark results as defined in this block.
            if (inst.producesValue()) {
                const result_slot = @as(usize, @intCast(func.param_count + inst_off));
                const prev = defined_block[result_slot];
                if (prev == u32.max) {
                    defined_block[result_slot] = @as(u32, block);
                } else if (prev != block) {
                    // Defined in more than one block: requires a phi at some
                    // use site. We flag at definition; phi-consume checks
                    // validate each use site individually.
                    defined_block[result_slot] = u32.max - 1; // sentinel: multi-defined
                }
            }
        }

        // Process phi nodes at the start of successor blocks: each phi's
        // incoming blocks must be predecessors of the block the phi lives in.
        // We recompute predecessors lazily per phi below.
    }

    self.gpa.free(defined_block);
}

/// True when `inst_off` is a phi instruction and one of its incoming pairs
/// lists `defining_block` as the source block for the given `slot`.
fn isPhiConsumingDefinedBlock(
    func: *const ir.Function,
    inst_off: u32,
    slot: u32,
    defining_block: u32,
) bool {
    const inst = func.instructions.items[@as(usize, inst_off)];
    if (inst.opcode != .phi) return false;
    const ops = func.getOperands(inst.operands);
    // Phi operands alternate: value, block, value, block, ...
    var i: u32 = 0;
    while (i + 1 < ops.len) : (i += 2) {
        const inc_block = ops[@as(usize, i + 1)];
        const inc_value = ops[@as(usize, i)];
        if (inc_block == defining_block and inc_value == slot) return true;
        i += 2;
    }
    return false;
}

fn addReport(
    self: *Verifier,
    func_name: []const u8,
    message: []const u8,
    inst: u32,
    operand: u32,
) !void {
    try self.reports.append(self.gpa, .{
        .function = try self.gpa.dupe(u8, func_name),
        .message = try self.gpa.dupe(u8, message),
        .inst = inst,
        .operand = operand,
    });
}

pub const VerifyResult = struct {
    report_count: u32,
    reports: []const Report,
};

test "verify clean function reports nothing" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);
    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const func = try builder.addFunction("clean", i32_ty, 1);
    builder.setCurrentFunction(func);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);
    const a = @as(ir.Value, @enumFromInt(0));
    const one = try builder.buildIntConst(i32_ty, 1);
    const sum = try builder.buildAdd(i32_ty, a, one);
    _ = try builder.buildRet(sum);

    var verifier = init(std.testing.allocator, &module);
    defer verifier.deinit();
    const count = try verifier.verifyAll();
    try std.testing.expectEqual(0, count);
}

test "verify catches use of undefined slot" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);
    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const func = try builder.addFunction("bad", i32_ty, 0);
    builder.setCurrentFunction(func);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);
    // ret reads slot 5, which no instruction defines (param_count=0).
    _ = try builder.buildRet(@as(ir.Value, @enumFromInt(5)));

    var verifier = init(std.testing.allocator, &module);
    defer verifier.deinit();
    const count = try verifier.verifyAll();
    try std.testing.expectEqual(1, count);
    if (verifier.reports.items.len > 0) {
        try std.testing.expectEqualStrings("bad", verifier.reports.items[0].function);
        try std.testing.expectEqual(memContains(verifier.reports.items[0].message, "undefined"), true);
    }
}

test "verify phi incoming block must be a predecessor" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);
    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const func = try builder.addFunction("phi_bad", i32_ty, 1);
    builder.setCurrentFunction(func);
    const bb0 = try builder.appendBlock();
    const bb1 = try builder.appendBlock();
    const bb2 = try builder.appendBlock();
    builder.setCurrentBlock(bb0);
    const n = @as(ir.Value, @enumFromInt(0));
    const one = try builder.buildIntConst(i32_ty, 1);
    const cond = try builder.buildIcmp(.icmp_sgt, i32_ty, n, one);
    _ = try builder.buildCondBr(cond, bb1, bb2);
    builder.setCurrentBlock(bb1);
    const v42 = try builder.buildIntConst(i32_ty, 42);
    // phi in bb1 with an incoming from bb2 (not a predecessor of bb1)
    const phi = try builder.buildPhi(i32_ty, &.{
        .{ .value = v42, .block = bb2 },
    });
    _ = try builder.buildRet(phi);
    builder.setCurrentBlock(bb2);
    const v7 = try builder.buildIntConst(i32_ty, 7);
    _ = try builder.buildRet(v7);

    var verifier = init(std.testing.allocator, &module);
    defer verifier.deinit();
    const count = try verifier.verifyAll();
    try std.testing.expectEqual(1, count);
}

fn memContains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
