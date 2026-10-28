//! Comprehensive closure / first-class-function backend tests.
//!
//! Each scenario is verified at three levels:
//!   1. semantics — the built module is executed by a minimal straight-line
//!      IR interpreter (see `Interpreter`), so capture-by-value, env slot
//!      layout, and indirect dispatch through the `{ fn_ptr, env_ptr }`
//!      record are checked for real results, not just text;
//!   2. textual IR — creation-site shape (func_addr pairing, env allocas,
//!      call_ptr);
//!   3. x86-64 asm — env-first marshaling, record materialization, and the
//!      indirect `call rax` sequence.

const std = @import("std");
const api = @import("api.zig");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;
const Value = api.Value;
const IrType = api.IrType;

// ============================================================================
// Test-support: minimal IR interpreter
// ============================================================================

/// Straight-line interpreter over the IR subset used by these tests:
/// `iconst`, `add`/`sub`/`mul`, `alloca`, `load`/`store`, `ptr_add`,
/// `func_addr`, `call`, `call_ptr`, `ret`. Anything else (branches, phi,
/// floats, ...) returns `error.UnsupportedOpcode`, keeping the tests honest
/// about what they exercise.
///
/// Memory model: one flat bump-allocated arena backing every `alloca`;
/// pointers are byte offsets into it. `func_addr` encodes a function
/// address as `FunctionIdx + 1` so that 0 stays a null marker, and
/// `call_ptr` decodes it, loading `env_ptr` from record+8 as the callee's
/// hidden argument 0 (the uniform env-first ABI the asm codegen emits).
const Interpreter = struct {
    gpa: Allocator,
    module: *const ir.Module,
    memory: std.ArrayList(u8),
    depth: u32,

    fn init(gpa: Allocator, module: *const ir.Module) Interpreter {
        return .{ .gpa = gpa, .module = module, .memory = .empty, .depth = 0 };
    }

    fn deinit(self: *Interpreter) void {
        self.memory.deinit(self.gpa);
    }

    fn slotValue(values: std.AutoArrayHashMapUnmanaged(Value, i64), v: u32) !i64 {
        return values.get(@enumFromInt(v)) orelse error.MissingValue;
    }

    fn allocaBytes(self: *Interpreter, size: u32) !i64 {
        const start = (self.memory.items.len + 7) & ~@as(usize, 7);
        try self.memory.resize(self.gpa, start + size);
        @memset(self.memory.items[start..], 0);
        return @intCast(start);
    }

    fn readInt(self: *Interpreter, offset: i64) !i64 {
        if (offset < 0) return error.InvalidPointer;
        const start: usize = @intCast(offset);
        if (start + 8 > self.memory.items.len) return error.OutOfBoundsRead;
        return std.mem.readInt(i64, self.memory.items[start..][0..8], .little);
    }

    fn writeInt(self: *Interpreter, offset: i64, value: i64) !void {
        if (offset < 0) return error.InvalidPointer;
        const start: usize = @intCast(offset);
        if (start + 8 > self.memory.items.len) return error.OutOfBoundsWrite;
        std.mem.writeInt(i64, self.memory.items[start..][0..8], value, .little);
    }

    /// Execute `func` with `args` bound to its parameters (including the
    /// hidden env parameter 0 for lifted closure bodies) and return the
    /// `ret` operand.
    fn call(self: *Interpreter, func_idx: ir.FunctionIdx, args: []const i64) anyerror!i64 {
        if (self.depth >= 128) return error.CallDepthExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        const func = &self.module.functions.items[@intFromEnum(func_idx)];
        if (args.len != func.param_count) return error.ArityMismatch;

        var values: std.AutoArrayHashMapUnmanaged(Value, i64) = .{};
        defer values.deinit(self.gpa);
        for (args, 0..) |arg, i| {
            try values.put(self.gpa, @enumFromInt(@as(u32, @intCast(i))), arg);
        }

        for (func.instructions.items, 0..) |inst, idx| {
            const ops = func.getOperands(inst.operands);
            const dst: Value = @enumFromInt(func.param_count + @as(u32, @intCast(idx)));
            switch (inst.opcode) {
                .iconst => {
                    const bits: u64 = (@as(u64, ops[1]) << 32) | ops[0];
                    try values.put(self.gpa, dst, @bitCast(bits));
                },
                .add, .sub, .mul => |op| {
                    const a = try slotValue(values, ops[0]);
                    const b = try slotValue(values, ops[1]);
                    const r = switch (op) {
                        .add => a +% b,
                        .sub => a -% b,
                        .mul => a *% b,
                        else => unreachable,
                    };
                    try values.put(self.gpa, dst, r);
                },
                .alloca => try values.put(
                    self.gpa,
                    dst,
                    try self.allocaBytes(if (ops.len == 0) 8 else ops[0]),
                ),
                .load => try values.put(self.gpa, dst, try self.readInt(try slotValue(values, ops[0]))),
                .store => try self.writeInt(try slotValue(values, ops[0]), try slotValue(values, ops[1])),
                .ptr_add => try values.put(
                    self.gpa,
                    dst,
                    (try slotValue(values, ops[0])) +% (try slotValue(values, ops[1])),
                ),
                .func_addr => try values.put(self.gpa, dst, @as(i64, @intCast(ops[0])) + 1),
                .call, .call_ptr => {
                    var call_args: [16]i64 = undefined;
                    var count: usize = 0;
                    var record: i64 = 0;
                    if (inst.opcode == .call_ptr) {
                        // The operand is the record's address; hidden
                        // argument 0 is its env_ptr (record+8).
                        record = try slotValue(values, ops[0]);
                        call_args[count] = try self.readInt(record + 8);
                        count += 1;
                    }
                    for (ops[1..]) |arg| {
                        call_args[count] = try slotValue(values, arg);
                        count += 1;
                    }
                    const ret = if (inst.opcode == .call)
                        try self.call(@enumFromInt(ops[0]), call_args[0..count])
                    else blk: {
                        // fn_ptr is stored at record+0; func_addr encoded it
                        // as `FunctionIdx + 1` so 0 stays a null marker.
                        const fn_ptr = try self.readInt(record);
                        if (fn_ptr == 0) return error.NullFnPointer;
                        break :blk try self.call(@enumFromInt(@as(u32, @intCast(fn_ptr - 1))), call_args[0..count]);
                    };
                    try values.put(self.gpa, dst, ret);
                },
                .ret => return try slotValue(values, ops[0]),
                else => return error.UnsupportedOpcode,
            }
        }
        return error.MissingReturn;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "env record layout: scalar slots and inline fn-value records" {
    const ctx = try api.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i64_ty = try ctx.intType(true, 64);
    const i64_ptr_ty = try ctx.ptrType(i64_ty);
    const sig = try ctx.funcType(i64_ty, &.{i64_ty});
    const fv_ty = try ctx.fnValueType(sig);

    // Env layout (docs/semantics.md §5.2 R8a): one 8-byte slot per scalar
    // capture, the full 16-byte record inline for a fn-value capture
    // (§6.4 R16d).
    try std.testing.expectEqual(@as(u32, 8), ctx.envRecordSize(&.{i64_ty}));
    try std.testing.expectEqual(@as(u32, 16), ctx.envRecordSize(&.{ i64_ty, i64_ty }));
    try std.testing.expectEqual(@as(u32, 16), ctx.envRecordSize(&.{fv_ty}));
    try std.testing.expectEqual(@as(u32, 24), ctx.envRecordSize(&.{ i64_ty, fv_ty }));
    try std.testing.expectEqual(@as(u32, 32), ctx.envRecordSize(&.{ i64_ty, fv_ty, i64_ty }));
    try std.testing.expectEqual(@as(u32, 32), ctx.envRecordSize(&.{ fv_ty, fv_ty }));

    // A plain fn reference: no captures, so a null env (R8b). The hidden
    // env parameter is ignored: double the visible argument.
    const plain = try ctx.addFunction("__plain", i64_ty, 2);
    ctx.setCurrentFunction(plain);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        const two = try ctx.buildIntConst(i64_ty, 2);
        _ = try ctx.buildRet(try ctx.buildMul(i64_ty, ctx.getParam(1), two));
    }

    // Lifted closure reading both scalar slots of a mixed record:
    // a at env+0, b at env+24 (the inline fn-value record fills env+8..24).
    const lifted = try ctx.addFunction("__with_fn", i64_ty, 2);
    ctx.setCurrentFunction(lifted);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        const env_param = ctx.getParam(0);
        const x = ctx.getParam(1);
        const a = try ctx.buildLoad(i64_ty, env_param);
        const b_slot = try ctx.buildPtrAdd(i64_ptr_ty, env_param, try ctx.buildIntConst(i64_ty, 24));
        const b = try ctx.buildLoad(i64_ty, b_slot);
        const scaled = try ctx.buildMul(i64_ty, a, try ctx.buildIntConst(i64_ty, 100));
        _ = try ctx.buildRet(try ctx.buildAdd(i64_ty, try ctx.buildAdd(i64_ty, scaled, b), x));
    }

    // Creation site: env = [ 4 @0, plain-record @8..24, 3 @24 ].
    const site = try ctx.addFunction("site", i64_ty, 0);
    ctx.setCurrentFunction(site);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const plain_addr = try ctx.buildFuncAddr(i64_ty, plain);
    const null_env = try ctx.buildIntConst(i64_ty, 0);
    const plain_fv = try ctx.buildFnValue(fv_ty, plain_addr, null_env);

    const four = try ctx.buildIntConst(i64_ty, 4);
    const three = try ctx.buildIntConst(i64_ty, 3);
    const env = try ctx.buildEnvRecord(&.{
        .{ .type_idx = i64_ty, .value = four },
        .{ .type_idx = fv_ty, .value = plain_fv },
        .{ .type_idx = i64_ty, .value = three },
    });

    const lifted_addr = try ctx.buildFuncAddr(i64_ty, lifted);
    const with_fn_fv = try ctx.buildFnValue(fv_ty, lifted_addr, env);
    const r1 = try ctx.buildCallPtr(i64_ty, with_fn_fv, &.{try ctx.buildIntConst(i64_ty, 2)});
    const r2 = try ctx.buildCallPtr(i64_ty, plain_fv, &.{try ctx.buildIntConst(i64_ty, 21)});
    _ = try ctx.buildRet(try ctx.buildAdd(i64_ty, r1, r2));

    // 4*100 + 3 + 2 = 405 through the mixed record; 21*2 = 42 through the
    // plain reference.
    var interp = Interpreter.init(std.testing.allocator, &ctx.module);
    defer interp.deinit();
    try std.testing.expectEqual(@as(i64, 447), try interp.call(site, &.{}));

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ctx.print(&w);
    const text = buf[0..w.end];

    // The mixed record reserves all 32 bytes in one frame block; the plain
    // record reserves its 16.
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
}

test "closure round-trip: capture, func_addr pairing, call-through-ptr" {
    const ctx = try api.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i64_ty = try ctx.intType(true, 64);
    const sig = try ctx.funcType(i64_ty, &.{i64_ty});
    const fv_ty = try ctx.fnValueType(sig);

    // The visible signature is the callee without its hidden env parameter
    // (docs/semantics.md §3.3, §6.2).
    try std.testing.expectEqual(
        IrType{ .function_value = .{ .signature = sig } },
        ctx.getType(fv_ty),
    );

    // Lifted body: fn add_from_env(env: ptr, x: i64) -> i64.
    const lifted = try ctx.addFunction("add_from_env", i64_ty, 2);
    ctx.setCurrentFunction(lifted);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        const captured = try ctx.buildLoad(i64_ty, ctx.getParam(0));
        _ = try ctx.buildRet(try ctx.buildAdd(i64_ty, captured, ctx.getParam(1)));
    }

    // Creation + call site: env captures 40 by value, the fn value pairs
    // the lifted callee's address with the env record's address, and the
    // indirect call passes the visible argument.
    const run = try ctx.addFunction("run", i64_ty, 1);
    ctx.setCurrentFunction(run);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const fn_addr = try ctx.buildFuncAddr(i64_ty, lifted);
    const forty = try ctx.buildIntConst(i64_ty, 40);
    const env = try ctx.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = forty }});
    const fv = try ctx.buildFnValue(fv_ty, fn_addr, env);
    const result = try ctx.buildCallPtr(i64_ty, fv, &.{ctx.getParam(0)});
    _ = try ctx.buildRet(result);

    // Execution round-trip: run(2) == 42.
    var interp = Interpreter.init(std.testing.allocator, &ctx.module);
    defer interp.deinit();
    try std.testing.expectEqual(@as(i64, 42), try interp.call(run, &.{2}));

    // An empty capture set produces no record and pairs with a null env.
    try std.testing.expectEqual(Value.none, try ctx.buildEnvRecord(&.{}));

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ctx.print(&w);
    const text = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr") != null);

    // Asm round-trip: the record is materialized in the frame, the env is
    // marshaled as hidden argument 0, and the call goes through the address
    // loaded from record+0.
    const asm_text = try ctx.emitAssembly();
    defer ctx.gpa.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lea     rax, [rel _add_from_env]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     [rax], rdx") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rcx, qword [r10+8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rax, qword [r10+0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call    rax") != null);
    // The visible argument shifts one register slot: rdx, not rcx.
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rdx, [rbp") != null);
}

test "capture-only closure: zero visible args marshals env alone" {
    const ctx = try api.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i64_ty = try ctx.intType(true, 64);
    const sig = try ctx.funcType(i64_ty, &.{}); // visible arity 0
    const fv_ty = try ctx.fnValueType(sig);

    const lifted = try ctx.addFunction("read_capture", i64_ty, 1);
    ctx.setCurrentFunction(lifted);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        _ = try ctx.buildRet(try ctx.buildLoad(i64_ty, ctx.getParam(0)));
    }

    const run = try ctx.addFunction("run", i64_ty, 0);
    ctx.setCurrentFunction(run);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const fn_addr = try ctx.buildFuncAddr(i64_ty, lifted);
    const seven = try ctx.buildIntConst(i64_ty, 7);
    const env = try ctx.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = seven }});
    const fv = try ctx.buildFnValue(fv_ty, fn_addr, env);
    _ = try ctx.buildRet(try ctx.buildCallPtr(i64_ty, fv, &.{}));

    var interp = Interpreter.init(std.testing.allocator, &ctx.module);
    defer interp.deinit();
    try std.testing.expectEqual(@as(i64, 7), try interp.call(run, &.{}));

    const asm_text = try ctx.emitAssembly();
    defer ctx.gpa.free(asm_text);

    // rcx receives only the hidden env; no visible argument follows it.
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rcx, qword [r10+8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call    rax") != null);
}

test "multi-arg closure: hidden env plus stack-spilled visible args" {
    const ctx = try api.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i64_ty = try ctx.intType(true, 64);
    // Five visible args: with the hidden env the callee reads six, so the
    // last two spill past the four register slots.
    const sig = try ctx.funcType(i64_ty, &.{ i64_ty, i64_ty, i64_ty, i64_ty, i64_ty });
    const fv_ty = try ctx.fnValueType(sig);

    const lifted = try ctx.addFunction("sum_with_capture", i64_ty, 6);
    ctx.setCurrentFunction(lifted);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        var acc = try ctx.buildLoad(i64_ty, ctx.getParam(0)); // hidden env
        inline for (1..6) |i| {
            acc = try ctx.buildAdd(i64_ty, acc, ctx.getParam(i));
        }
        _ = try ctx.buildRet(acc);
    }

    const run = try ctx.addFunction("run", i64_ty, 5);
    ctx.setCurrentFunction(run);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const fn_addr = try ctx.buildFuncAddr(i64_ty, lifted);
    const hundred = try ctx.buildIntConst(i64_ty, 100);
    const env = try ctx.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = hundred }});
    const fv = try ctx.buildFnValue(fv_ty, fn_addr, env);
    const args = [_]Value{
        ctx.getParam(0), ctx.getParam(1), ctx.getParam(2), ctx.getParam(3), ctx.getParam(4),
    };
    _ = try ctx.buildRet(try ctx.buildCallPtr(i64_ty, fv, &args));

    var interp = Interpreter.init(std.testing.allocator, &ctx.module);
    defer interp.deinit();
    try std.testing.expectEqual(@as(i64, 115), try interp.call(run, &.{ 1, 2, 3, 4, 5 }));

    const asm_text = try ctx.emitAssembly();
    defer ctx.gpa.free(asm_text);

    // Hidden env in rcx; visible args fill rdx/r8/r9 and spill to stack
    // slots 32 and 40 (after the 32-byte shadow space).
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rcx, qword [r10+8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     r9, [rbp") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     [rsp + 32], rax") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     [rsp + 40], rax") != null);
}

test "nested closure: inner closure created and called inside an outer closure body" {
    const ctx = try api.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i64_ty = try ctx.intType(true, 64);
    const sig = try ctx.funcType(i64_ty, &.{i64_ty});
    const fv_ty = try ctx.fnValueType(sig);

    // Inner: fn mul_add(env: ptr, x: i64) -> i64 — reads its capture.
    const inner = try ctx.addFunction("mul_add", i64_ty, 2);
    ctx.setCurrentFunction(inner);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        const captured = try ctx.buildLoad(i64_ty, ctx.getParam(0));
        _ = try ctx.buildRet(try ctx.buildAdd(i64_ty, captured, ctx.getParam(1)));
    }

    // Outer: fn apply_outer(env: ptr, x: i64) -> i64 — captures the
    // multiplier, then creates *and* calls the inner closure inside its own
    // body, capturing the value it just loaded from its env.
    const outer = try ctx.addFunction("apply_outer", i64_ty, 2);
    ctx.setCurrentFunction(outer);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        const m = try ctx.buildLoad(i64_ty, ctx.getParam(0));
        const inner_addr = try ctx.buildFuncAddr(i64_ty, inner);
        const inner_env = try ctx.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = m }});
        const inner_fv = try ctx.buildFnValue(fv_ty, inner_addr, inner_env);
        const inner_r = try ctx.buildCallPtr(i64_ty, inner_fv, &.{ctx.getParam(1)});
        _ = try ctx.buildRet(try ctx.buildAdd(i64_ty, inner_r, m));
    }

    // run(m, x): outer(x) + nothing = mul_add(m, x) + m.
    const run = try ctx.addFunction("run", i64_ty, 2);
    ctx.setCurrentFunction(run);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const m = ctx.getParam(0);
    const outer_env = try ctx.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = m }});
    const outer_addr = try ctx.buildFuncAddr(i64_ty, outer);
    const outer_fv = try ctx.buildFnValue(fv_ty, outer_addr, outer_env);
    _ = try ctx.buildRet(try ctx.buildCallPtr(i64_ty, outer_fv, &.{ctx.getParam(1)}));

    // (3 + 5) + 3 = 11: the inner env must hold the *dynamically loaded*
    // capture, not a constant.
    var interp = Interpreter.init(std.testing.allocator, &ctx.module);
    defer interp.deinit();
    try std.testing.expectEqual(@as(i64, 11), try interp.call(run, &.{ 3, 5 }));

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ctx.print(&w);
    const text = buf[0..w.end];

    // Both creation sites pair a callee address with an env record
    // (fn0 = mul_add, fn1 = apply_outer in the textual IR).
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn1") != null);

    const asm_text = try ctx.emitAssembly();
    defer ctx.gpa.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lea     rax, [rel _mul_add]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lea     rax, [rel _apply_outer]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call    rax") != null);
}

test "closure-in-closure: fn-value capture copied inline into the env record" {
    const ctx = try api.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i64_ty = try ctx.intType(true, 64);
    const i64_ptr_ty = try ctx.ptrType(i64_ty);
    const sig = try ctx.funcType(i64_ty, &.{i64_ty});
    const fv_ty = try ctx.fnValueType(sig);

    // Outer: fn apply_outer(env: ptr, x: i64) -> i64 — its env holds
    // [ m @0, inner-fn-value @8..24 ]. The inline copy must be
    // word-for-word (both fn_ptr and env_ptr, §6.4 R16d): the record
    // pointer for the indirect call is the slot address itself.
    const outer = try ctx.addFunction("apply_outer", i64_ty, 2);
    ctx.setCurrentFunction(outer);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        const env_param = ctx.getParam(0);
        const x = ctx.getParam(1);
        const m = try ctx.buildLoad(i64_ty, env_param);
        const inner_record = try ctx.buildPtrAdd(i64_ptr_ty, env_param, try ctx.buildIntConst(i64_ty, 8));
        const inner_r = try ctx.buildCallPtr(i64_ty, inner_record, &.{x});
        _ = try ctx.buildRet(try ctx.buildAdd(i64_ty, inner_r, m));
    }

    // Inner: fn mul_add(env: ptr, x: i64) -> i64 — reads its capture.
    const inner = try ctx.addFunction("mul_add", i64_ty, 2);
    ctx.setCurrentFunction(inner);
    {
        const entry = try ctx.appendBlock();
        ctx.setCurrentBlock(entry);
        const captured = try ctx.buildLoad(i64_ty, ctx.getParam(0));
        _ = try ctx.buildRet(try ctx.buildAdd(i64_ty, captured, ctx.getParam(1)));
    }

    // run(x): m = 7; build the inner closure, then capture both m and the
    // whole fn value into the outer closure's env.
    const run = try ctx.addFunction("run", i64_ty, 1);
    ctx.setCurrentFunction(run);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const seven = try ctx.buildIntConst(i64_ty, 7);
    const inner_env = try ctx.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = seven }});
    const inner_addr = try ctx.buildFuncAddr(i64_ty, inner);
    const inner_fv = try ctx.buildFnValue(fv_ty, inner_addr, inner_env);
    const outer_env = try ctx.buildEnvRecord(&.{
        .{ .type_idx = i64_ty, .value = seven },
        .{ .type_idx = fv_ty, .value = inner_fv },
    });
    const outer_addr = try ctx.buildFuncAddr(i64_ty, outer);
    const outer_fv = try ctx.buildFnValue(fv_ty, outer_addr, outer_env);
    _ = try ctx.buildRet(try ctx.buildCallPtr(i64_ty, outer_fv, &.{ctx.getParam(0)}));

    // inner(5) = 7 + 5; apply_outer adds m again: (7 + 5) + 7 = 19. A
    // word-corrupted env_ptr copy would dispatch into garbage here.
    var interp = Interpreter.init(std.testing.allocator, &ctx.module);
    defer interp.deinit();
    try std.testing.expectEqual(@as(i64, 19), try interp.call(run, &.{5}));

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ctx.print(&w);
    const text = buf[0..w.end];

    // The outer env is one 24-byte block: 8-byte scalar + inline record
    // (fn0 = apply_outer, fn1 = mul_add in the textual IR).
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 24") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn1") != null);

    const asm_text = try ctx.emitAssembly();
    defer ctx.gpa.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lea     rax, [rel _mul_add]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lea     rax, [rel _apply_outer]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call    rax") != null);
}
