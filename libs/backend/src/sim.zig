const std = @import("std");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;

/// A register/slot machine that executes Tungsten IR directly, mirroring
/// `codegen.zig`'s frame layout. Each value lives in one 8-byte slot at a
/// fixed offset from a frame base. This isolates codegen bugs from linker/
/// object-emission bugs without emitting native code.
pub const Simulator = struct {
    gpa: Allocator,
    module: *const ir.Module,

    // The simulated frame: every value slot is an i64 (8 bytes). Slot index
    // N corresponds to offset -8*(N+1) from the frame base (like codegen's
    // `[rbp + off]`), stored flat for simplicity. Params occupy slots
    // 0..param_count; instruction results occupy param_count+.
    slots: std.ArrayList(i64),
    /// Whether each slot has been defined (to detect use of uninitialized
    /// slots).
    defined: std.ArrayList(bool),

    /// Program counter: index of the current instruction within the current
    /// function's flat instruction list.
    pc: usize,
    /// Currently executing function index.
    current_func: usize,
    /// Currently executing block index within the current function.
    current_block: usize,
    /// The block we entered the current block from (for phi resolution).
    prev_block: usize,
    /// Block entry PC for each block (start instruction index).
    block_pcs: []usize,
    /// Number of instructions per block.
    block_counts: []u32,

    /// Return value of the last executed function (i64 bits).
    retval: i64,
    /// Whether the current function has executed `ret`/`ret_void`.
    halted: bool,
    /// Trace output writer (optional).
    trace: ?*std.Io.Writer,

    /// Stack of return frames for calls.
    call_stack: std.ArrayList(CallFrame),

    // ============================================================================
    // Lifecycle
    // ============================================================================

    pub fn init(
        gpa: Allocator,
        module: *const ir.Module,
        func_idx: usize,
    ) !Simulator {
        var sim = Simulator{
            .gpa = gpa,
            .module = module,
            .slots = .empty,
            .defined = .empty,
            .pc = 0,
            .current_func = func_idx,
            .current_block = 0,
            .prev_block = 0,
            .block_pcs = undefined,
            .block_counts = undefined,
            .retval = 0,
            .halted = false,
            .trace = null,
            .call_stack = .empty,
        };
        sim.buildBlockMap(func_idx);
        return sim;
    }

    pub fn deinit(self: *Simulator) void {
        self.slots.deinit(self.gpa);
        self.defined.deinit(self.gpa);
        self.call_stack.deinit(self.gpa);
    }

    pub fn setTrace(self: *Simulator, w: *std.Io.Writer) void {
        self.trace = w;
    }

    // ============================================================================
    // Block map
    // ============================================================================

    /// Build a flat block map (entry PC + count per block) for the current
    /// function so branches can jump by block index.
    fn buildBlockMap(self: *Simulator, func_idx: usize) void {
        const func = &self.module.functions.items[func_idx];
        const nblocks = func.blocks.items.len;
        self.block_pcs = self.gpa.alloc(usize, nblocks) catch unreachable;
        self.block_counts = self.gpa.alloc(u32, nblocks) catch unreachable;
        var pc: usize = 0;
        for (func.blocks.items, 0..) |block, i| {
            self.block_pcs[i] = pc;
            self.block_counts[i] = block.inst_count;
            pc += @intCast(block.inst_count);
        }
    }

    // ============================================================================
    // Slot access
    // ============================================================================

    /// Ensure `slots`/`defined` are large enough for `slot_index`.
    fn ensureSlot(self: *Simulator, slot_index: u32) !void {
        const idx = @as(usize, @intCast(slot_index));
        while (self.slots.items.len <= idx) {
            try self.slots.append(self.gpa, 0);
            try self.defined.append(self.gpa, false);
        }
    }

    /// Read a value slot. `slot_index` is a Value (0..param_count are params,
    /// param_count+ are instruction results).
    fn readSlot(self: *Simulator, slot_index: u32) !i64 {
        try self.ensureSlot(slot_index);
        const idx = @as(usize, @intCast(slot_index));
        if (!self.defined.items[idx]) {
            return error.UninitializedSlot;
        }
        return self.slots.items[idx];
    }

    fn writeSlot(self: *Simulator, slot_index: u32, value: i64) !void {
        try self.ensureSlot(slot_index);
        const idx = @as(usize, @intCast(slot_index));
        self.slots.items[idx] = value;
        self.defined.items[idx] = true;
    }

    // ============================================================================
    // Execution
    // ============================================================================

    /// Execute the current function from the current PC until it returns
    /// (`ret`/`ret_void`) or traps. Calls to other functions are handled
    /// recursively via `doCall`. Returns when the current function executes
    /// `ret`.
    pub fn run(self: *Simulator) !void {
        while (true) {
            const func = &self.module.functions.items[self.current_func];
            if (self.pc >= func.instructions.items.len) {
                return error.InvalidBranchTarget;
            }
            const inst = func.instructions.items[self.pc];
            const result_slot = @as(u32, @intCast(func.param_count + self.pc));
            const action = try self.executeInstruction(func, inst, result_slot);
            if (self.halted) {
                if (self.call_stack.items.len == 0) break; // top-level return
                // Callee executed `ret`: pop the frame and resume the caller.
                const frame_idx = self.call_stack.items.len - 1;
                const frame = self.call_stack.items[frame_idx];
                self.call_stack.items = self.call_stack.items[0..frame_idx];
                self.current_func = frame.func;
                self.current_block = frame.block;
                self.prev_block = frame.prev_block;
                self.pc = frame.pc;
                self.halted = false;
                if (frame.retval_slot != std.math.maxInt(usize)) {
                    try self.writeSlot(@intCast(frame.retval_slot), self.retval);
                }
                continue;
            }
            if (action == .advance) self.pc += 1;
        }
    }

    /// Execute a single instruction. Returns whether the PC should advance by
    /// one (`.advance`) or was already set by a branch (`.set`).
    fn executeInstruction(
        self: *Simulator,
        func: *const ir.Function,
        inst: ir.Instruction,
        result_slot: u32,
    ) !PcAction {
        const ops = func.getOperands(inst.operands);
        switch (inst.opcode) {
            .iconst => {
                const bits: u64 = (@as(u64, ops[1]) << 32) | ops[0];
                try self.writeSlot(result_slot, @bitCast(bits));
                self.traceInst("iconst", result_slot, @as(i64, @bitCast(bits)));
            },
            .fconst => {
                const bits: u64 = (@as(u64, ops[1]) << 32) | ops[0];
                try self.writeSlot(result_slot, @bitCast(bits));
                self.traceInst("fconst", result_slot, @as(i64, @bitCast(bits)));
            },
            .add => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                try self.writeSlot(result_slot, a + b);
                self.traceInst("add", result_slot, a + b);
            },
            .sub => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                try self.writeSlot(result_slot, a - b);
                self.traceInst("sub", result_slot, a - b);
            },
            .mul => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                try self.writeSlot(result_slot, a * b);
                self.traceInst("mul", result_slot, a * b);
            },
            .sdiv => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                if (b == 0) return error.DivideByZero;
                try self.writeSlot(result_slot, @divTrunc(a, b));
                self.traceInst("sdiv", result_slot, @divTrunc(a, b));
            },
            .udiv => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                if (b == 0) return error.DivideByZero;
                const au: u64 = @bitCast(a);
                const bu: u64 = @bitCast(b);
                try self.writeSlot(result_slot, @bitCast(au / bu));
                self.traceInst("udiv", result_slot, @bitCast(au / bu));
            },
            .srem => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                if (b == 0) return error.DivideByZero;
                try self.writeSlot(result_slot, @rem(a, b));
                self.traceInst("srem", result_slot, @rem(a, b));
            },
            .urem => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                if (b == 0) return error.DivideByZero;
                const au: u64 = @bitCast(a);
                const bu: u64 = @bitCast(b);
                try self.writeSlot(result_slot, @bitCast(au % bu));
                self.traceInst("urem", result_slot, @bitCast(au % bu));
            },
            .and_op => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                try self.writeSlot(result_slot, a & b);
                self.traceInst("and", result_slot, a & b);
            },
            .or_op => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                try self.writeSlot(result_slot, a | b);
                self.traceInst("or", result_slot, a | b);
            },
            .xor_op => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                try self.writeSlot(result_slot, a ^ b);
                self.traceInst("xor", result_slot, a ^ b);
            },
            .shl => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                const count: u6 = @intCast(b);
                try self.writeSlot(result_slot, a << count);
                self.traceInst("shl", result_slot, a << count);
            },
            .shr => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                const signed = switch (self.module.getIrType(inst.type_idx)) {
                    .int => |it| it.signed,
                    else => false,
                };
                const count: u6 = @intCast(b);
                const signed_res: i64 = a >> count;
                const au: u64 = @bitCast(a);
                const bu: u6 = @intCast(b);
                const unsigned_res: i64 = @bitCast(au >> bu);
                const res: i64 = if (signed) signed_res else unsigned_res;
                try self.writeSlot(result_slot, res);
                self.traceInst("shr", result_slot, res);
            },
            .fadd, .fsub, .fmul, .fdiv => |op| {
                const a = @as(f64, @bitCast(try self.readSlot(ops[0])));
                const b = @as(f64, @bitCast(try self.readSlot(ops[1])));
                const res: f64 = switch (op) {
                    .fadd => a + b,
                    .fsub => a - b,
                    .fmul => a * b,
                    .fdiv => a / b,
                    else => unreachable,
                };
                try self.writeSlot(result_slot, @bitCast(res));
                self.traceInst(@tagName(op), result_slot, @bitCast(res));
            },
            .icmp_eq, .icmp_ne, .icmp_slt, .icmp_sle, .icmp_sgt, .icmp_sge,
            .icmp_ult, .icmp_ule, .icmp_ugt, .icmp_uge => |cond| {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                const au: u64 = @bitCast(a);
                const bu: u64 = @bitCast(b);
                const res: bool = switch (cond) {
                    .icmp_eq => a == b,
                    .icmp_ne => a != b,
                    .icmp_slt => a < b,
                    .icmp_sle => a <= b,
                    .icmp_sgt => a > b,
                    .icmp_sge => a >= b,
                    .icmp_ult => au < bu,
                    .icmp_ule => au <= bu,
                    .icmp_ugt => au > bu,
                    .icmp_uge => au >= bu,
                    else => unreachable,
                };
                try self.writeSlot(result_slot, if (res) 1 else 0);
                self.traceInst(@tagName(cond), result_slot, if (res) 1 else 0);
            },
            .fcmp_oeq, .fcmp_one, .fcmp_olt, .fcmp_ole, .fcmp_ogt, .fcmp_oge => |cond| {
                const a = @as(f64, @bitCast(try self.readSlot(ops[0])));
                const b = @as(f64, @bitCast(try self.readSlot(ops[1])));
                const res: bool = switch (cond) {
                    .fcmp_oeq => a == b,
                    .fcmp_one => a != b,
                    .fcmp_olt => a < b,
                    .fcmp_ole => a <= b,
                    .fcmp_ogt => a > b,
                    .fcmp_oge => a >= b,
                    else => unreachable,
                };
                try self.writeSlot(result_slot, if (res) 1 else 0);
                self.traceInst(@tagName(cond), result_slot, if (res) 1 else 0);
            },
            .br => {
                const target = @as(usize, @intCast(ops[0]));
                try self.jumpToBlock(target);
                return .set;
            },
            .cond_br => {
                const cond = try self.readSlot(ops[0]);
                const true_block = @as(usize, @intCast(ops[1]));
                const false_block = @as(usize, @intCast(ops[2]));
                if (cond != 0) {
                    try self.jumpToBlock(true_block);
                } else {
                    try self.jumpToBlock(false_block);
                }
                return .set;
            },
            .ret => {
                const val = try self.readSlot(ops[0]);
                self.retval = val;
                self.halted = true;
                self.traceInst("ret", ops[0], val);
            },
            .ret_void => {
                self.halted = true;
                self.traceInst("ret_void", 0, 0);
            },
            .call => {
                const callee = @as(usize, @intCast(ops[0]));
                try self.enterFrame(callee, ops[1..], result_slot);
                return .set;
            },
            .call_ptr => {
                // ops[0] is a fn_value slot: { fn_ptr at +0, env_ptr at +8 }.
                // In this simulator `func_addr` writes the callee function index
                // into its slot, and `buildFnValue` stores both words, so the
                // fn_ptr word holds the callee index.
                const fv_slot = ops[0];
                const fn_ptr = try self.readSlot(fv_slot);
                const callee = @as(usize, @intCast(fn_ptr));
                try self.enterFrame(callee, ops[1..], result_slot);
                _ = try self.readSlot(fv_slot + 1); // env_ptr (opaque in sim)
                return .set;
            },
            .extern_call => {
                const ext_idx = @as(usize, @intCast(ops[0]));
                const ext_name = self.module.strings.get(self.module.externs.items[ext_idx].name);
                _ = ext_name;
                return error.ExternalCallUnimplemented;
            },
            .alloca => {
                const size: u32 = if (ops.len == 0) 8 else ops[0];
                const slots_needed = (size + 7) / 8;
                const base_index = @as(u32, @intCast(self.slots.items.len));
                try self.ensureSlot(base_index + slots_needed - 1);
                try self.writeSlot(result_slot, @intCast(base_index));
                self.traceInst("alloca", result_slot, @intCast(base_index));
            },
            .load => {
                const ptr = try self.readSlot(ops[0]);
                const base_index: u32 = @intCast(@as(u64, @bitCast(ptr)));
                const loaded = try self.readSlot(base_index);
                try self.writeSlot(result_slot, loaded);
                self.traceInst("load", result_slot, loaded);
            },
            .store => {
                const ptr = try self.readSlot(ops[0]);
                const val = try self.readSlot(ops[1]);
                const base_index: u32 = @intCast(@as(u64, @bitCast(ptr)));
                try self.writeSlot(base_index, val);
                self.traceInst("store", ops[1], val);
            },
            .ptr_add => {
                const a = try self.readSlot(ops[0]);
                const b = try self.readSlot(ops[1]);
                try self.writeSlot(result_slot, a + b);
                self.traceInst("ptr_add", result_slot, a + b);
            },
            .malloc => return error.MallocUnimplemented,
            .global_addr => {
                const gidx = @as(usize, @intCast(ops[0]));
                const gidx_i64: i64 = @intCast(gidx);
                try self.writeSlot(result_slot, 1000 + gidx_i64);
                self.traceInst("global_addr", result_slot, 1000 + gidx_i64);
            },
            .func_addr => {
                const fidx = @as(usize, @intCast(ops[0]));
                try self.writeSlot(result_slot, @intCast(fidx));
                self.traceInst("func_addr", result_slot, @intCast(fidx));
            },
            .phi => {
                var found: ?i64 = null;
                var i: usize = 0;
                while (i + 1 < ops.len) : (i += 2) {
                    const inc_block = @as(usize, @intCast(ops[i + 1]));
                    if (inc_block == self.prev_block) {
                        found = try self.readSlot(ops[i]);
                        break;
                    }
                }
                const val = found orelse try self.readSlot(ops[0]);
                try self.writeSlot(result_slot, val);
                self.traceInst("phi", result_slot, val);
            },
        }
        return .advance;
    }

    fn jumpToBlock(self: *Simulator, target: usize) !void {
        const func = &self.module.functions.items[self.current_func];
        if (target >= func.blocks.items.len) return error.InvalidBranchTarget;
        self.prev_block = self.current_block;
        self.current_block = target;
        self.pc = self.block_pcs[target];
    }

    /// Invoke a function (direct call). Pushes a return frame, copies arguments
    /// into parameter slots, and recurses into the callee. When the callee
    /// executes `ret`, its `run()` returns; we pop the frame, restore the caller
    /// state, store the return value, and the caller's `run()` loop continues.
    fn enterFrame(
        self: *Simulator,
        callee: usize,
        args: []const u32,
        result_slot: u32,
    ) !void {
        const callee_func = &self.module.functions.items[callee];
        const resume_pc = self.pc + 1;
        try self.call_stack.append(self.gpa, .{
            .func = self.current_func,
            .block = self.current_block,
            .prev_block = self.prev_block,
            .pc = resume_pc,
            .retval_slot = @intCast(result_slot),
        });
        // Switch to callee frame.
        self.current_func = callee;
        self.current_block = 0;
        self.pc = 0;
        self.halted = false;
        // Copy args into param slots.
        for (args, 0..) |arg, i| {
            if (i >= callee_func.param_count) break;
            const v = try self.readSlot(arg);
            try self.writeSlot(@intCast(i), v);
        }
    }

    // ============================================================================
    // Convenience
    // ============================================================================

    /// Convenience: run `func_idx` with no arguments and return the result.
    pub fn runFunction(
        gpa: Allocator,
        module: *const ir.Module,
        func_idx: usize,
    ) !RunResult {
        var sim = try init(gpa, module, func_idx);
        defer sim.deinit();
        _ = sim.run() catch |e| return RunResult{ .retval = 0, .halted = false, .err = e };
        return RunResult{ .retval = sim.retval, .halted = true, .err = null };
    }

    fn traceInst(self: *Simulator, name: []const u8, slot: u32, value: i64) void {
        if (self.trace) |w| {
            _ = w.print("{s} %{d} = {d}\n", .{ name, slot, value }) catch {};
        }
    }
};

pub const CallFrame = struct {
    func: usize,
    block: usize,
    prev_block: usize,
    pc: usize,
    /// Slot index where the caller wants the return value stored (or usize
    /// max if the call result is discarded).
    retval_slot: usize,
};

pub const SimError = error{
    OutOfBoundsSlot,
    UninitializedSlot,
    StackOverflow,
    DivideByZero,
    UnsupportedOpcode,
    MissingBlock,
    InvalidBranchTarget,
    ExternalCallUnimplemented,
    MallocUnimplemented,
};

/// Result of running a function: the return value (i64 bits).
pub const RunResult = struct {
    retval: i64,
    halted: bool,
    err: ?SimError,
};

pub const PcAction = enum { advance, set };

test "sim executes add of two params" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);
    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const func = try builder.addFunction("add", i32_ty, 2);
    builder.setCurrentFunction(func);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);
    const a = @as(ir.Value, @enumFromInt(0));
    const b = @as(ir.Value, @enumFromInt(1));
    const sum = try builder.buildAdd(i32_ty, a, b);
    _ = try builder.buildRet(sum);

    var sim = try Simulator.init(std.testing.allocator, &module, @as(usize, @intFromEnum(func)));
    defer sim.deinit();
    try sim.writeSlot(0, 3);
    try sim.writeSlot(1, 7);
    try sim.run();
    try std.testing.expectEqual(10, sim.retval);
}

test "sim executes conditional branch between two blocks" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);
    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const func = try builder.addFunction("pick", i32_ty, 1);
    builder.setCurrentFunction(func);
    const bb0 = try builder.appendBlock();
    const bb1 = try builder.appendBlock();
    const bb2 = try builder.appendBlock();
    builder.setCurrentBlock(bb0);
    const flag = @as(ir.Value, @enumFromInt(0));
    const zero = try builder.buildIntConst(i32_ty, 0);
    const cond = try builder.buildIcmp(.icmp_eq, i32_ty, flag, zero);
    _ = try builder.buildCondBr(cond, bb1, bb2);
    builder.setCurrentBlock(bb1);
    const v42 = try builder.buildIntConst(i32_ty, 42);
    _ = try builder.buildRet(v42);
    builder.setCurrentBlock(bb2);
    const v7 = try builder.buildIntConst(i32_ty, 7);
    _ = try builder.buildRet(v7);

    // flag == 0 → bb1 → 42
    {
        var sim = try Simulator.init(std.testing.allocator, &module, @as(usize, @intFromEnum(func)));
        defer sim.deinit();
        try sim.writeSlot(0, 0);
        try sim.run();
        try std.testing.expectEqual(42, sim.retval);
    }
    // flag != 0 → bb2 → 7
    {
        var sim = try Simulator.init(std.testing.allocator, &module, @as(usize, @intFromEnum(func)));
        defer sim.deinit();
        try sim.writeSlot(0, 1);
        try sim.run();
        try std.testing.expectEqual(7, sim.retval);
    }
}

test "sim detects uninitialized slot read" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);
    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const func = try builder.addFunction("use_undef", i32_ty, 0);
    builder.setCurrentFunction(func);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);
    // ret reads slot 5, which no instruction defines (param_count=0).
    _ = try builder.buildRet(@as(ir.Value, @enumFromInt(5)));

    var sim = try Simulator.init(std.testing.allocator, &module, @as(usize, @intFromEnum(func)));
    defer sim.deinit();
    const err = sim.run() catch |e| e;
    try std.testing.expectEqual(error.UninitializedSlot, err);
}

test "sim executes function call" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);
    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const callee = try builder.addFunction("callee", i32_ty, 1);
    builder.setCurrentFunction(callee);
    const c_entry = try builder.appendBlock();
    builder.setCurrentBlock(c_entry);
    const n = @as(ir.Value, @enumFromInt(0));
    const doubled = try builder.buildMul(i32_ty, n, @as(ir.Value, @enumFromInt(0)));
    _ = doubled;
    _ = try builder.buildRet(n);

    const caller = try builder.addFunction("caller", i32_ty, 1);
    builder.setCurrentFunction(caller);
    const m_entry = try builder.appendBlock();
    builder.setCurrentBlock(m_entry);
    const arg = @as(ir.Value, @enumFromInt(0));
    _ = try builder.buildCall(callee, i32_ty, &.{arg});
    const one = try builder.buildIntConst(i32_ty, 1);
    const result = try builder.buildAdd(i32_ty, one, @as(ir.Value, @enumFromInt(1)));
    _ = try builder.buildRet(result);

    // caller(5) -> callee(5) returns 5; 1 + 5 = 6
    var sim = try Simulator.init(std.testing.allocator, &module, @as(usize, @intFromEnum(caller)));
    defer sim.deinit();
    try sim.writeSlot(0, 5);
    try sim.run();
    try std.testing.expectEqual(6, sim.retval);
}
