//! Tungsten Frontend API
//!
//! High-level, ergonomic API for frontend compilers written in Zig to construct
//! Tungsten IR and generate native code.
//!
//! This is the recommended interface for driving Tungsten from a frontend.
//! It wraps the low-level IR builder with a single `Context` object that owns
//! all module state and provides methods for type creation, function definition,
//! instruction building, and code emission.
//!
//! Example — building a simple `add` function:
//!
//! ```zig
//! const tungsten = @import("Tungsten");
//! const api = tungsten.api;
//!
//! fn buildAdd(ctx: *api.Context) !void {
//!     const i32 = try ctx.intType(true, 32);
//!
//!     const func = try ctx.addFunction("add", i32, 2);
//!     ctx.setCurrentFunction(func);
//!
//!     const entry = try ctx.appendBlock();
//!     ctx.setCurrentBlock(entry);
//!
//!     const a = ctx.getParam(0);
//!     const b = ctx.getParam(1);
//!     const sum = try ctx.buildAdd(i32, a, b);
//!     _ = try ctx.buildRet(sum);
//! }
//! ```

const std = @import("std");
const ir = @import("ir.zig");
const codegen = @import("codegen.zig");
const Allocator = std.mem.Allocator;

// ============================================================================
// Re-exports — handle types for use by frontends without importing ir.zig
// ============================================================================

pub const Value = ir.Value;
pub const TypeIdx = ir.TypeIdx;
pub const FunctionIdx = ir.FunctionIdx;
pub const BasicBlockIdx = ir.BasicBlockIdx;
pub const Opcode = ir.Opcode;
pub const FloatType = ir.FloatType;
pub const IrType = ir.IrType;
pub const IntType = ir.IntType;
pub const PointerType = ir.PointerType;
pub const FunctionType = ir.FunctionType;
pub const FunctionValueType = ir.FunctionValueType;
pub const PhiIncoming = ir.PhiIncoming;
pub const GlobalIdx = ir.GlobalIdx;

/// Byte size of a fn-value record: `{ fn_ptr: u64, env_ptr: u64 }`.
pub const fn_value_size = ir.fn_value_size;

// ============================================================================
// Context
// ============================================================================

/// The top-level entry point for constructing Tungsten IR.
///
/// A `Context` owns the IR module and instruction builder. All types, functions,
/// basic blocks, and instructions are created through this object.
///
/// The context is heap-allocated via `init` and freed via `deinit`.
pub const Context = struct {
    gpa: Allocator,
    module: ir.Module,
    builder: ir.Builder,

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Create a new Tungsten context.
    ///
    /// Allocates the context on the heap so that internal pointers (e.g. the
    /// builder's reference to the module) remain stable.
    /// The caller must free via `deinit`.
    pub fn init(gpa: Allocator) !*Context {
        const ctx = try gpa.create(Context);
        ctx.* = .{
            .gpa = gpa,
            .module = .empty,
            .builder = undefined,
        };
        ctx.builder = ir.Builder.init(gpa, &ctx.module);
        return ctx;
    }

    /// Destroy the context and release all associated memory.
    pub fn deinit(self: *Context) void {
        self.module.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    // ========================================================================
    // Type System
    // ========================================================================

    /// Create a void type.
    pub fn voidType(self: *Context) !TypeIdx {
        return self.builder.addVoidType();
    }

    /// Create a boolean type.
    pub fn boolType(self: *Context) !TypeIdx {
        return self.builder.addBoolType();
    }

    /// Create an integer type with the given signedness and bit width.
    pub fn intType(self: *Context, signed: bool, bits: u16) !TypeIdx {
        return self.builder.addIntType(signed, bits);
    }

    /// Create a floating-point type (f16, f32, or f64).
    pub fn floatType(self: *Context, ft: FloatType) !TypeIdx {
        return self.builder.addFloatType(ft);
    }

    /// Create a pointer type pointing to `elem`.
    pub fn ptrType(self: *Context, elem: TypeIdx) !TypeIdx {
        return self.builder.addPointerType(elem);
    }

    /// Create a function type with the given return type and parameter types.
    pub fn funcType(self: *Context, ret: TypeIdx, param_types: []const TypeIdx) !TypeIdx {
        return self.builder.addFunctionType(ret, param_types);
    }

    /// Create a fn-value type whose visible callee signature is `signature`
    /// (a `function` type). The runtime record is `fn_value_size` bytes:
    /// `{ fn_ptr, env_ptr }` (docs/semantics.md §3.3).
    pub fn fnValueType(self: *Context, signature: TypeIdx) !TypeIdx {
        return self.builder.addFunctionValueType(signature);
    }

    /// Look up a type by its index.
    pub fn getType(self: *Context, idx: TypeIdx) IrType {
        return self.module.getIrType(idx);
    }

    /// Return the number of types registered in the module.
    pub fn getTypeCount(self: *Context) usize {
        return self.module.types.items.len;
    }

    // ========================================================================
    // Functions
    // ========================================================================

    /// Add a new function to the module.
    ///
    /// After creation call `setCurrentFunction` to begin building its body.
    pub fn addFunction(self: *Context, name: []const u8, return_type: TypeIdx, param_count: u32) !FunctionIdx {
        return self.builder.addFunction(name, return_type, param_count);
    }

    /// Set the current function for subsequent block / instruction insertion.
    pub fn setCurrentFunction(self: *Context, func: FunctionIdx) void {
        self.builder.setCurrentFunction(func);
    }

    /// Get a reference to a function by index.
    pub fn getFunction(self: *Context, idx: FunctionIdx) *ir.Function {
        return &self.module.functions.items[@intFromEnum(idx)];
    }

    /// Return the number of functions in the module.
    pub fn getFunctionCount(self: *Context) usize {
        return self.module.functions.items.len;
    }

    /// Get the name of a function.
    pub fn getFunctionName(self: *Context, idx: FunctionIdx) []const u8 {
        const func = self.module.functions.items[@intFromEnum(idx)];
        return self.module.strings.get(func.name);
    }

    /// Return the number of basic blocks in the given function.
    pub fn getBlockCountIn(self: *Context, idx: FunctionIdx) usize {
        return self.module.functions.items[@intFromEnum(idx)].blocks.items.len;
    }

    /// Return the number of instructions in the given function.
    pub fn getInstructionCountIn(self: *Context, idx: FunctionIdx) usize {
        return self.module.functions.items[@intFromEnum(idx)].instructions.items.len;
    }

    // ========================================================================
    // Globals
    // ========================================================================

    /// Add a string-literal global. The data is emitted NUL-terminated in the
    /// .data section and addressed via `buildGlobalAddr`.
    pub fn addStringGlobal(self: *Context, name: []const u8, data: []const u8) !GlobalIdx {
        return self.builder.addStringGlobal(name, data);
    }

    /// Add a vtable global: an array of function pointers, one per virtual
    /// method, in declaration order.
    pub fn addFnArrayGlobal(self: *Context, name: []const u8, funcs: []const FunctionIdx) !GlobalIdx {
        return self.builder.addFnArrayGlobal(name, funcs);
    }

    /// Return the number of globals in the module.
    pub fn getGlobalCount(self: *Context) usize {
        return self.module.globals.items.len;
    }

    // ========================================================================
    // Basic Blocks
    // ========================================================================

    /// Append a new basic block to the current function.
    ///
    /// Panics if no current function has been set via `setCurrentFunction`.
    pub fn appendBlock(self: *Context) !BasicBlockIdx {
        return self.builder.appendBlock();
    }

    /// Set the current insertion point to the end of the given basic block.
    pub fn setCurrentBlock(self: *Context, block: BasicBlockIdx) void {
        self.builder.setCurrentBlock(block);
    }

    // ========================================================================
    // Parameter Access
    // ========================================================================

    /// Get the SSA value handle for a function parameter.
    ///
    /// Parameters are numbered from 0. The Nth parameter of the current
    /// function is `getParam(N)`.
    pub fn getParam(_: *Context, index: u32) Value {
        return @enumFromInt(index);
    }

    // ========================================================================
    // Instruction Building — Constants
    // ========================================================================

    /// Materialize an integer constant.
    pub fn buildIntConst(self: *Context, type_idx: TypeIdx, value: i64) !Value {
        return self.builder.buildIntConst(type_idx, value);
    }

    /// Materialize a floating-point constant.
    pub fn buildFloatConst(self: *Context, type_idx: TypeIdx, value: f64) !Value {
        return self.builder.buildFloatConst(type_idx, value);
    }

    // ========================================================================
    // Instruction Building — Arithmetic
    // ========================================================================

    pub fn buildAdd(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildAdd(type_idx, lhs, rhs);
    }

    pub fn buildSub(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildSub(type_idx, lhs, rhs);
    }

    pub fn buildMul(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildMul(type_idx, lhs, rhs);
    }

    pub fn buildSDiv(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildSDiv(type_idx, lhs, rhs);
    }

    pub fn buildUDiv(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildUDiv(type_idx, lhs, rhs);
    }

    pub fn buildSRem(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildSRem(type_idx, lhs, rhs);
    }

    pub fn buildURem(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildURem(type_idx, lhs, rhs);
    }

    pub fn buildFAdd(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildFAdd(type_idx, lhs, rhs);
    }

    pub fn buildFSub(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildFSub(type_idx, lhs, rhs);
    }

    pub fn buildFMul(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildFMul(type_idx, lhs, rhs);
    }

    pub fn buildFDiv(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildFDiv(type_idx, lhs, rhs);
    }

    // ========================================================================
    // Instruction Building — Bitwise
    // ========================================================================

    pub fn buildAnd(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildAnd(type_idx, lhs, rhs);
    }

    pub fn buildOr(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildOr(type_idx, lhs, rhs);
    }

    pub fn buildXor(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildXor(type_idx, lhs, rhs);
    }

    pub fn buildShl(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildShl(type_idx, lhs, rhs);
    }

    pub fn buildShr(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildShr(type_idx, lhs, rhs);
    }

    // ========================================================================
    // Instruction Building — Comparison
    // ========================================================================

    /// Build an integer comparison.
    ///
    /// `cond` must be one of the `icmp_*` opcodes (e.g. `.icmp_eq`, `.icmp_slt`).
    pub fn buildIcmp(self: *Context, cond: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildIcmp(cond, type_idx, lhs, rhs);
    }

    /// Build a floating-point comparison.
    ///
    /// `cond` must be one of the `fcmp_*` opcodes (e.g. `.fcmp_olt`).
    pub fn buildFCmp(self: *Context, cond: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.builder.buildFCmp(cond, type_idx, lhs, rhs);
    }

    // ========================================================================
    // Instruction Building — Control Flow
    // ========================================================================

    /// Build an unconditional branch to `target`.
    pub fn buildBr(self: *Context, target: BasicBlockIdx) !Value {
        return self.builder.buildBr(target);
    }

    /// Build a conditional branch: branch to `true_block` if `cond` is nonzero,
    /// otherwise to `false_block`.
    pub fn buildCondBr(self: *Context, cond: Value, true_block: BasicBlockIdx, false_block: BasicBlockIdx) !Value {
        return self.builder.buildCondBr(cond, true_block, false_block);
    }

    /// Build a return instruction.
    pub fn buildRet(self: *Context, val: Value) !Value {
        return self.builder.buildRet(val);
    }

    /// Build a return instruction for void functions.
    pub fn buildRetVoid(self: *Context) !Value {
        return self.builder.buildRetVoid();
    }

    // ========================================================================
    // Instruction Building — Function Calls
    // ========================================================================

    /// Build a call to `func` passing the given arguments.
    pub fn buildCall(self: *Context, func: FunctionIdx, type_idx: TypeIdx, args: []const Value) !Value {
        return self.builder.buildCall(func, type_idx, args);
    }

    /// Build an indirect call through the function pointer `callee`.
    pub fn buildCallPtr(self: *Context, type_idx: TypeIdx, callee: Value, args: []const Value) !Value {
        return self.builder.buildCallPtr(type_idx, callee, args);
    }

    /// Materialize a fn value: the `fn_value_size`-byte `{ fn_ptr, env_ptr }`
    /// record, placed in the current frame. The produced value is the
    /// record's address. `type_idx` must be a `fnValueType` type; `fn_ptr`
    /// holds the callee's address and `env_ptr` the captured-env record's
    /// address (or null for a plain fn reference).
    pub fn buildFnValue(self: *Context, type_idx: TypeIdx, fn_ptr: Value, env_ptr: Value) !Value {
        return self.builder.buildFnValue(type_idx, fn_ptr, env_ptr);
    }

    /// Build a call to an external C function by name (e.g. `puts`).
    pub fn buildExternCall(self: *Context, name: []const u8, type_idx: TypeIdx, args: []const Value) !Value {
        return self.builder.buildExternCall(name, type_idx, args);
    }

    // ========================================================================
    // Instruction Building — Memory
    // ========================================================================

    /// Allocate stack space for `type_idx`. Returns a pointer value.
    pub fn buildAlloca(self: *Context, type_idx: TypeIdx) !Value {
        return self.builder.buildAlloca(type_idx);
    }

    /// Allocate `size_bytes` of stack space, aligned to 8 bytes.
    /// Returns a pointer to the start of the block.
    pub fn buildAllocaBytes(self: *Context, type_idx: TypeIdx, size_bytes: u32) !Value {
        return self.builder.buildAllocaBytes(type_idx, size_bytes);
    }

    /// Load a value of `type_idx` from `ptr`.
    pub fn buildLoad(self: *Context, type_idx: TypeIdx, ptr: Value) !Value {
        return self.builder.buildLoad(type_idx, ptr);
    }

    /// Store `val` (of `type_idx`) through `ptr`.
    pub fn buildStore(self: *Context, type_idx: TypeIdx, ptr: Value, val: Value) !Value {
        return self.builder.buildStore(type_idx, ptr, val);
    }

    /// Compute `ptr + offset` (unscaled byte offset).
    pub fn buildPtrAdd(self: *Context, type_idx: TypeIdx, ptr: Value, offset: Value) !Value {
        return self.builder.buildPtrAdd(type_idx, ptr, offset);
    }

    /// Heap-allocate `size` bytes. Returns a pointer to the allocation.
    pub fn buildMalloc(self: *Context, type_idx: TypeIdx, size: Value) !Value {
        return self.builder.buildMalloc(type_idx, size);
    }

    /// Take the address of a module-level global.
    pub fn buildGlobalAddr(self: *Context, type_idx: TypeIdx, global: GlobalIdx) !Value {
        return self.builder.buildGlobalAddr(type_idx, global);
    }

    // ========================================================================
    // Instruction Building — SSA
    // ========================================================================

    /// Build a phi node with the given incoming (value, block) pairs.
    pub fn buildPhi(self: *Context, type_idx: TypeIdx, incoming: []const PhiIncoming) !Value {
        return self.builder.buildPhi(type_idx, incoming);
    }

    // ========================================================================
    // Output — Textual IR
    // ========================================================================

    /// Print the module's textual IR representation to `writer`.
    pub fn print(self: *Context, writer: anytype) !void {
        try ir.printModule(&self.module, writer);
    }

    // ========================================================================
    // Output — Native Code
    // ========================================================================

    /// Emit x86-64 NASM assembly for the entire module.
    ///
    /// Returns an allocated byte slice that the caller must free with
    /// `ctx.gpa.free(result)`.
    pub fn emitAssembly(self: *Context) ![]u8 {
        var cg = codegen.CodeGen.init(self.gpa, &self.module);
        defer cg.deinit();
        try cg.emitModule();
        return self.gpa.dupe(u8, cg.buf.items);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "context lifecycle" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.getFunctionCount());
}

test "type creation" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const void_ty = try ctx.voidType();
    const bool_ty = try ctx.boolType();
    const i32_ty = try ctx.intType(true, 32);
    const u8_ty = try ctx.intType(false, 8);
    const f32_ty = try ctx.floatType(.f32);
    const ptr_ty = try ctx.ptrType(i32_ty);

    try std.testing.expectEqual(@as(usize, 6), ctx.getTypeCount());

    // Verify round-trip
    try std.testing.expectEqual(IrType.void, ctx.getType(void_ty));
    try std.testing.expectEqual(IrType.bool_type, ctx.getType(bool_ty));
    try std.testing.expectEqual(IrType{ .int = .{ .signed = true, .bits = 32 } }, ctx.getType(i32_ty));
    try std.testing.expectEqual(IrType{ .int = .{ .signed = false, .bits = 8 } }, ctx.getType(u8_ty));
    try std.testing.expectEqual(IrType{ .float = .f32 }, ctx.getType(f32_ty));
    try std.testing.expectEqual(IrType{ .pointer = .{ .elem = i32_ty } }, ctx.getType(ptr_ty));
}

test "function and instruction building" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);
    _ = try ctx.voidType();

    // int add(int a, int b) { return a + b; }
    const func = try ctx.addFunction("add", i32_ty, 2);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);
    const sum = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildRet(sum);

    try std.testing.expectEqual(@as(usize, 1), ctx.getFunctionCount());
    try std.testing.expectEqual(@as(usize, 1), ctx.getBlockCountIn(func));
    try std.testing.expectEqual(@as(usize, 2), ctx.getInstructionCountIn(func));
    try std.testing.expectEqualStrings("add", ctx.getFunctionName(func));
}

test "fibonacci with control flow" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);

    // fn fib(i32 %n) -> i32
    const fib = try ctx.addFunction("fib", i32_ty, 1);
    ctx.setCurrentFunction(fib);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const n = ctx.getParam(0);
    const zero = @as(Value, @enumFromInt(0));
    const cond = try ctx.buildIcmp(.icmp_sle, i32_ty, n, zero);

    const base = try ctx.appendBlock();
    const recurse = try ctx.appendBlock();
    _ = try ctx.buildCondBr(cond, base, recurse);

    ctx.setCurrentBlock(base);
    _ = try ctx.buildRet(n);

    ctx.setCurrentBlock(recurse);
    _ = try ctx.buildRet(n);

    try std.testing.expectEqual(@as(usize, 1), ctx.getFunctionCount());
    try std.testing.expectEqual(@as(usize, 3), ctx.getBlockCountIn(fib));
}

test "print textual IR" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);

    const func = try ctx.addFunction("main", i32_ty, 0);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const zero = @as(Value, @enumFromInt(0));
    _ = try ctx.buildRet(zero);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ctx.print(&w);
    const text = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, text, "@main") != null);
}

test "all binary opcodes compile" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(false, 32);

    const func = try ctx.addFunction("test_ops", i32_ty, 2);
    ctx.setCurrentFunction(func);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);

    _ = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildSub(i32_ty, a, b);
    _ = try ctx.buildMul(i32_ty, a, b);
    _ = try ctx.buildSDiv(i32_ty, a, b);
    _ = try ctx.buildUDiv(i32_ty, a, b);
    _ = try ctx.buildAnd(i32_ty, a, b);
    _ = try ctx.buildOr(i32_ty, a, b);
    _ = try ctx.buildXor(i32_ty, a, b);
    _ = try ctx.buildShl(i32_ty, a, b);
    _ = try ctx.buildShr(i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_eq, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ne, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_slt, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_sle, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_sgt, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_sge, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ult, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ule, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_ugt, i32_ty, a, b);
    _ = try ctx.buildIcmp(.icmp_uge, i32_ty, a, b);

    try std.testing.expectEqual(@as(usize, 20), ctx.getInstructionCountIn(func));
}

test "memory and call instructions" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);
    const ptr_ty = try ctx.ptrType(i32_ty);

    const callee = try ctx.addFunction("callee", i32_ty, 1);
    const caller = try ctx.addFunction("caller", i32_ty, 1);
    ctx.setCurrentFunction(caller);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const n = ctx.getParam(0);

    // alloca + store + load
    const alloca = try ctx.buildAlloca(ptr_ty);
    _ = try ctx.buildStore(i32_ty, alloca, n);
    const loaded = try ctx.buildLoad(i32_ty, alloca);

    // call
    _ = try ctx.buildCall(callee, i32_ty, &.{loaded});

    _ = try ctx.buildRet(loaded);

    try std.testing.expectEqual(@as(usize, 2), ctx.getFunctionCount());
    try std.testing.expectEqual(@as(usize, 5), ctx.getInstructionCountIn(caller));
}

test "extended opcodes" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const f64_ty = try ctx.floatType(.f64);
    const ptr_ty = try ctx.ptrType(f64_ty);
    const void_ty = try ctx.voidType();
    const i32_ty = try ctx.intType(true, 32);

    const helper = try ctx.addFunction("helper", void_ty, 0);
    ctx.setCurrentFunction(helper);
    const h_entry = try ctx.appendBlock();
    ctx.setCurrentBlock(h_entry);
    _ = try ctx.buildRetVoid();

    const str_global = try ctx.addStringGlobal("greeting", "hello world");
    const vt_global = try ctx.addFnArrayGlobal("vtable", &.{helper});

    const func = try ctx.addFunction("float_main", i32_ty, 2);
    ctx.setCurrentFunction(func);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);

    _ = try ctx.buildFAdd(f64_ty, a, b);
    _ = try ctx.buildFSub(f64_ty, a, b);
    _ = try ctx.buildFMul(f64_ty, a, b);
    _ = try ctx.buildFDiv(f64_ty, a, b);
    _ = try ctx.buildFCmp(.fcmp_olt, f64_ty, a, b);
    _ = try ctx.buildSRem(i32_ty, a, b);
    _ = try ctx.buildURem(i32_ty, a, b);
    const ptr = try ctx.buildPtrAdd(ptr_ty, a, b);
    const alloc = try ctx.buildMalloc(ptr_ty, a);
    const sptr = try ctx.buildGlobalAddr(ptr_ty, str_global);
    _ = try ctx.buildCallPtr(i32_ty, sptr, &.{ a, b });
    _ = try ctx.buildStore(i32_ty, alloc, a);
    _ = try ctx.buildRet(ptr);

    try std.testing.expectEqual(@as(usize, 2), ctx.getGlobalCount());
    _ = vt_global;
}

test "emit assembly with globals floats and heap" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const void_ty = try ctx.voidType();
    const i64_ty = try ctx.intType(true, 64);
    const f64_ty = try ctx.floatType(.f64);
    const ptr_ty = try ctx.ptrType(i64_ty);

    const helper = try ctx.addFunction("helper", void_ty, 0);
    ctx.setCurrentFunction(helper);
    const h_entry = try ctx.appendBlock();
    ctx.setCurrentBlock(h_entry);
    _ = try ctx.buildRetVoid();

    const str_global = try ctx.addStringGlobal("greeting", "hi");
    _ = try ctx.addFnArrayGlobal("vtable", &.{helper});

    const func = try ctx.addFunction("main", i64_ty, 0);
    ctx.setCurrentFunction(func);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const one = try ctx.buildIntConst(i64_ty, 1);
    const two = try ctx.buildIntConst(i64_ty, 2);
    const half = try ctx.buildFloatConst(f64_ty, 0.5);
    const sum = try ctx.buildFAdd(f64_ty, half, half);
    _ = try ctx.buildFCmp(.fcmp_oge, f64_ty, sum, half);
    _ = try ctx.buildSRem(i64_ty, two, one);
    const alloc = try ctx.buildMalloc(ptr_ty, one);
    const sptr = try ctx.buildGlobalAddr(ptr_ty, str_global);
    _ = try ctx.buildCallPtr(i64_ty, sptr, &.{ one, two });
    _ = try ctx.buildRet(alloc);

    const asm_text = try ctx.emitAssembly();
    defer ctx.gpa.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "section .data") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "__g0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "db 104, 105, 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "dq _helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "addsd") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "ucomisd") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call    malloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call    rax") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lea     rax, [rel __g0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "extern malloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rax, 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "movq    xmm0, rax") != null);
}

test "function type creation" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);
    const void_ty = try ctx.voidType();

    const fty = try ctx.funcType(i32_ty, &.{ i32_ty, i32_ty });
    _ = fty;
    const fty2 = try ctx.funcType(void_ty, &.{});
    _ = fty2;

    try std.testing.expectEqual(@as(usize, 4), ctx.getTypeCount());
}

test "function value model" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const i64_ty = try ctx.intType(true, 64);
    const sig = try ctx.funcType(i64_ty, &.{i64_ty});
    const fv_ty = try ctx.fnValueType(sig);

    try std.testing.expectEqual(
        IrType{ .function_value = .{ .signature = sig } },
        ctx.getType(fv_ty),
    );

    // Closure creation site: the env record holds the by-value capture, and
    // the fn value pairs the lifted callee's address with the env's address.
    const make = try ctx.addFunction("make_closure", fv_ty, 1);
    ctx.setCurrentFunction(make);
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const fn_ptr = ctx.getParam(0); // callee address (opaque here)
    const env = try ctx.buildAllocaBytes(i64_ty, 8);
    const capture = try ctx.buildIntConst(i64_ty, 7);
    _ = try ctx.buildStore(i64_ty, env, capture);
    const fv = try ctx.buildFnValue(fv_ty, fn_ptr, env);
    _ = try ctx.buildRet(fv);

    // env alloca + capture store, then buildFnValue's alloca/store/iconst/
    // ptr_add/store, then ret.
    try std.testing.expectEqual(@as(usize, 9), ctx.getInstructionCountIn(make));

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ctx.print(&w);
    const text = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
}
