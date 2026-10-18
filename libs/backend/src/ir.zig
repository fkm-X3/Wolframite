const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Handles - compact, typed, 32-bit integer indices into flat arrays
// ============================================================================

/// An SSA value. Function parameters occupy values `0..param_count`.
/// The result of the instruction at index `N` in a function's instruction
/// list is `Value(param_count + N)`.
pub const Value = enum(u32) {
    none = 0,
    _,
};

pub const TypeIdx = enum(u32) { _ };
pub const InstructionIdx = enum(u32) { _ };
pub const BasicBlockIdx = enum(u32) { _ };
pub const FunctionIdx = enum(u32) { _ };

// ============================================================================
// Opcode
// ============================================================================

pub const Opcode = enum(u8) {
    // Constants
    iconst,
    fconst,
    // Arithmetic
    add,
    sub,
    mul,
    sdiv,
    udiv,
    srem,
    urem,
    // Bitwise
    and_op,
    or_op,
    xor_op,
    shl,
    shr,
    // Floating point
    fadd,
    fsub,
    fmul,
    fdiv,
    // Comparison
    icmp_eq,
    icmp_ne,
    icmp_slt,
    icmp_sle,
    icmp_sgt,
    icmp_sge,
    icmp_ult,
    icmp_ule,
    icmp_ugt,
    icmp_uge,
    fcmp_oeq,
    fcmp_one,
    fcmp_olt,
    fcmp_ole,
    fcmp_ogt,
    fcmp_oge,
    // Control flow
    br,
    cond_br,
    ret,
    ret_void,
    call,
    /// Indirect call through a fn value (docs/semantics.md §6.4, R16c).
    /// Operand 0 is an SSA value of type `function_value`: the address of a
    /// `fn_value_size`-byte `{ fn_ptr, env_ptr }` record. Codegen loads
    /// `fn_ptr` from record+0 and `env_ptr` from record+8, passes `env_ptr`
    /// as the callee's hidden argument 0 (docs/semantics.md §6.2), and calls
    /// with the remaining operands as the visible arguments.
    call_ptr,
    /// Call an external C function (declared with `extern` in the emitted
    /// assembly). Operand 0 is an index into `Module.externs`.
    extern_call,
    // Memory
    alloca,
    load,
    store,
    ptr_add,
    malloc,
    // Globals
    global_addr,
    // SSA
    phi,
};

// ============================================================================
// Instruction
// ============================================================================

pub const OperandSlice = struct {
    start: u32,
    len: u16,
};

pub const Instruction = struct {
    opcode: Opcode,
    type_idx: TypeIdx,
    operands: OperandSlice,

    /// Returns whether this opcode produces an SSA value.
    pub fn producesValue(self: Instruction) bool {
        return switch (self.opcode) {
            .br, .cond_br, .ret, .ret_void, .store, .extern_call => false,
            else => true,
        };
    }
};

// ============================================================================
// BasicBlock
// ============================================================================

pub const BasicBlock = struct {
    first_inst: InstructionIdx,
    inst_count: u32,
};

// ============================================================================
// Types
// ============================================================================

pub const IrType = union(enum) {
    void,
    bool_type,
    int: IntType,
    float: FloatType,
    pointer: PointerType,
    function: FunctionType,
    /// A first-class fn value: a 16-byte `{ fn_ptr, env_ptr }` record
    /// (docs/semantics.md §3.3).
    function_value: FunctionValueType,
};

pub const IntType = struct {
    signed: bool,
    bits: u16,
};

pub const FloatType = enum(u16) {
    f16 = 16,
    f32 = 32,
    f64 = 64,
};

pub const PointerType = struct {
    elem: TypeIdx,
};

pub const FunctionType = struct {
    return_type: TypeIdx,
    param_types: []const TypeIdx,
};

/// The type of a first-class fn value (docs/semantics.md §3.3, R16a).
///
/// The runtime record is `fn_value_size` bytes: `fn_ptr` at offset 0 and
/// `env_ptr` at offset 8. `signature` is the *visible* callee signature — a
/// `function` type without the hidden env parameter (docs/semantics.md §6.2).
/// The captured env schema is per-instance lowering metadata and is
/// deliberately not part of the type identity (docs/semantics.md §4.1).
pub const FunctionValueType = struct {
    signature: TypeIdx,
};

/// Byte size of a fn-value record: `{ fn_ptr: u64, env_ptr: u64 }`.
pub const fn_value_size: u32 = 16;

// ============================================================================
// String Pool
// ============================================================================

pub const StringRef = struct {
    start: u32,
    len: u32,
};

pub const StringPool = struct {
    buffer: std.ArrayList(u8),

    pub const empty: StringPool = .{ .buffer = .empty };

    pub fn deinit(self: *StringPool, gpa: Allocator) void {
        self.buffer.deinit(gpa);
    }

    pub fn intern(self: *StringPool, gpa: Allocator, s: []const u8) !StringRef {
        const start: u32 = @intCast(self.buffer.items.len);
        try self.buffer.appendSlice(gpa, s);
        return .{ .start = start, .len = @intCast(s.len) };
    }

    pub fn get(self: StringPool, ref: StringRef) []const u8 {
        return self.buffer.items[ref.start..][0..ref.len];
    }
};

// ============================================================================
// Globals
// ============================================================================

pub const GlobalIdx = enum(u32) { _ };

/// A module-level global value, placed in the .data section of the emitted
/// assembly and addressed via the `global_addr` instruction.
pub const Global = struct {
    name: StringRef,
    kind: GlobalKind,
};

pub const GlobalKind = union(enum) {
    /// NUL-terminated byte string (a string literal).
    string: StringRef,
    /// Array of function pointers, one per virtual method (a vtable).
    /// Entries are indices into `Module.functions`.
    fn_array: []const u32,
};

// ============================================================================
// Function
// ============================================================================

pub const Function = struct {
    name: StringRef,
    return_type: TypeIdx,
    param_count: u32,
    blocks: std.ArrayList(BasicBlock),
    instructions: std.ArrayList(Instruction),
    /// Operand pool: flat u32 array referenced by Instruction.operands
    extra_data: std.ArrayList(u32),

    pub const empty: Function = .{
        .name = .{ .start = 0, .len = 0 },
        .return_type = @enumFromInt(0),
        .param_count = 0,
        .blocks = .empty,
        .instructions = .empty,
        .extra_data = .empty,
    };

    pub fn deinit(self: *Function, gpa: Allocator) void {
        self.blocks.deinit(gpa);
        self.instructions.deinit(gpa);
        self.extra_data.deinit(gpa);
    }

    pub fn getOperand(self: Function, val: Value) u32 {
        return self.extra_data.items[@intFromEnum(val)];
    }

    pub fn getOperands(self: Function, slice: OperandSlice) []const u32 {
        return self.extra_data.items[slice.start..][0..slice.len];
    }
};

// ============================================================================
// Closure Environments
// ============================================================================

/// One captured slot of a closure env record: the captured value's type and
/// the SSA value to copy into the record at creation time (by-value capture,
/// docs/semantics.md §5.2, R8c).
pub const EnvField = struct {
    type_idx: TypeIdx,
    value: Value,
};

/// Byte size of one env field slot.
///
/// Captures follow the backend's slot model: every type occupies one 8-byte
/// slot, except a `function_value` capture, which stores its 16-byte
/// `{ fn_ptr, env_ptr }` record inline (docs/semantics.md §6.4, R16d).
pub fn envFieldSize(module: *const Module, type_idx: TypeIdx) u32 {
    return switch (module.getIrType(type_idx)) {
        .function_value => fn_value_size,
        else => 8,
    };
}

/// Byte size of a closure env record holding the given captured field types
/// in declaration order (docs/semantics.md §5.2, R8a). Always a multiple of
/// 8, so every slot — including an inline `function_value` record — is
/// naturally aligned.
pub fn envRecordSize(module: *const Module, field_types: []const TypeIdx) u32 {
    var size: u32 = 0;
    for (field_types) |ty| size += envFieldSize(module, ty);
    return size;
}

// ============================================================================
// Externals
// ============================================================================

/// An external C function referenced by the module (e.g. `puts`, `malloc`).
/// Emitted as an `extern <name>` declaration in the assembly.
pub const ExternFunc = struct {
    name: StringRef,
};

// ============================================================================
// Module
// ============================================================================

pub const Module = struct {
    functions: std.ArrayList(Function),
    types: std.ArrayList(IrType),
    strings: StringPool,
    globals: std.ArrayList(Global),
    externs: std.ArrayList(ExternFunc),

    pub const empty: Module = .{
        .functions = .empty,
        .types = .empty,
        .strings = StringPool.empty,
        .globals = .empty,
        .externs = .empty,
    };

    pub fn deinit(self: *Module, gpa: Allocator) void {
        for (self.functions.items) |*f| f.deinit(gpa);
        self.functions.deinit(gpa);
        for (self.types.items) |ty| switch (ty) {
            .function => |ft| gpa.free(ft.param_types),
            else => {},
        };
        self.types.deinit(gpa);
        self.strings.deinit(gpa);
        for (self.globals.items) |global| switch (global.kind) {
            .string => {},
            .fn_array => |arr| gpa.free(arr),
        };
        self.globals.deinit(gpa);
        self.externs.deinit(gpa);
    }

    pub fn addType(self: *Module, gpa: Allocator, ir_type: IrType) !TypeIdx {
        const idx: u32 = @intCast(self.types.items.len);
        try self.types.append(gpa, ir_type);
        return @enumFromInt(idx);
    }

    pub fn getIrType(self: Module, idx: TypeIdx) IrType {
        return self.types.items[@intFromEnum(idx)];
    }

    pub fn addGlobal(self: *Module, gpa: Allocator, name: []const u8, kind: GlobalKind) !GlobalIdx {
        const name_ref = try self.strings.intern(gpa, name);
        const idx: u32 = @intCast(self.globals.items.len);
        try self.globals.append(gpa, .{ .name = name_ref, .kind = kind });
        return @enumFromInt(idx);
    }

    pub fn getGlobal(self: Module, idx: GlobalIdx) Global {
        return self.globals.items[@intFromEnum(idx)];
    }
};

// ============================================================================
// Builder - convenience API for constructing IR
// ============================================================================

pub const Builder = struct {
    gpa: Allocator,
    module: *Module,
    current_func: ?FunctionIdx,
    current_block: ?BasicBlockIdx,

    pub fn init(gpa: Allocator, module: *Module) Builder {
        return .{
            .gpa = gpa,
            .module = module,
            .current_func = null,
            .current_block = null,
        };
    }

    pub fn setCurrentFunction(self: *Builder, func: FunctionIdx) void {
        self.current_func = func;
        self.current_block = null;
    }

    pub fn setCurrentBlock(self: *Builder, block: BasicBlockIdx) void {
        self.current_block = block;
        // Pin the block's first_inst to the current end of the instruction
        // list so that all subsequent appends land in this block.
        const func = self.getCurrentFunction();
        func.blocks.items[@intFromEnum(block)].first_inst =
            @enumFromInt(@as(u32, @intCast(func.instructions.items.len)));
    }

    // -- Type helpers --

    pub fn addVoidType(self: *Builder) !TypeIdx {
        return self.module.addType(self.gpa, .void);
    }

    pub fn addBoolType(self: *Builder) !TypeIdx {
        return self.module.addType(self.gpa, .bool_type);
    }

    pub fn addIntType(self: *Builder, signed: bool, bits: u16) !TypeIdx {
        return self.module.addType(self.gpa, .{ .int = .{ .signed = signed, .bits = bits } });
    }

    pub fn addFloatType(self: *Builder, float: FloatType) !TypeIdx {
        return self.module.addType(self.gpa, .{ .float = float });
    }

    pub fn addPointerType(self: *Builder, elem: TypeIdx) !TypeIdx {
        return self.module.addType(self.gpa, .{ .pointer = .{ .elem = elem } });
    }

    pub fn addFunctionType(self: *Builder, ret: TypeIdx, param_types: []const TypeIdx) !TypeIdx {
        const owned = try self.gpa.dupe(TypeIdx, param_types);
        return self.module.addType(self.gpa, .{ .function = .{
            .return_type = ret,
            .param_types = owned,
        } });
    }

    /// Create a fn-value type whose visible callee signature is `signature`
    /// (a `function` type). The runtime record is `fn_value_size` bytes.
    pub fn addFunctionValueType(self: *Builder, signature: TypeIdx) !TypeIdx {
        return self.module.addType(self.gpa, .{ .function_value = .{ .signature = signature } });
    }

    // -- Function --

    pub fn addFunction(self: *Builder, name: []const u8, return_type: TypeIdx, param_count: u32) !FunctionIdx {
        const name_ref = try self.module.strings.intern(self.gpa, name);
        const idx: u32 = @intCast(self.module.functions.items.len);
        var func = Function.empty;
        func.name = name_ref;
        func.return_type = return_type;
        func.param_count = param_count;
        try self.module.functions.append(self.gpa, func);
        return @enumFromInt(idx);
    }

    pub fn getCurrentFunction(self: *Builder) *Function {
        return &self.module.functions.items[@intFromEnum(self.current_func.?)];
    }

    // -- Globals --

    /// Add a string-literal global. The data is interned in the module's
    /// string pool and emitted NUL-terminated in the .data section.
    pub fn addStringGlobal(self: *Builder, name: []const u8, data: []const u8) !GlobalIdx {
        const data_ref = try self.module.strings.intern(self.gpa, data);
        return self.module.addGlobal(self.gpa, name, .{ .string = data_ref });
    }

    /// Add a vtable global: an array of function pointers, one per virtual
    /// method, in declaration order.
    pub fn addFnArrayGlobal(self: *Builder, name: []const u8, funcs: []const FunctionIdx) !GlobalIdx {
        const owned = try self.gpa.alloc(u32, funcs.len);
        for (funcs, 0..) |func, i| owned[i] = @intFromEnum(func);
        return self.module.addGlobal(self.gpa, name, .{ .fn_array = owned });
    }

    // -- Basic Blocks --

    pub fn appendBlock(self: *Builder) !BasicBlockIdx {
        const func = self.getCurrentFunction();
        const idx: u32 = @intCast(func.blocks.items.len);
        try func.blocks.append(self.gpa, .{
            .first_inst = @enumFromInt(@as(u32, @intCast(func.instructions.items.len))),
            .inst_count = 0,
        });
        return @enumFromInt(idx);
    }

    pub fn getCurrentBlock(self: *Builder) *BasicBlock {
        return &self.getCurrentFunction().blocks.items[@intFromEnum(self.current_block.?)];
    }

    // -- Operand helpers --

    fn appendOperands(self: *Builder, operands: []const u32) !OperandSlice {
        const func = self.getCurrentFunction();
        const start: u32 = @intCast(func.extra_data.items.len);
        try func.extra_data.appendSlice(self.gpa, operands);
        return .{ .start = start, .len = @intCast(operands.len) };
    }

    fn appendInstruction(self: *Builder, inst: Instruction) !Value {
        const func = self.getCurrentFunction();
        const block = self.getCurrentBlock();
        const idx: u32 = @intCast(func.instructions.items.len);
        try func.instructions.append(self.gpa, inst);
        block.inst_count += 1;
        if (inst.producesValue()) {
            // Function parameters occupy values 0..param_count-1, so
            // instruction results start at param_count (matches codegen).
            return @enumFromInt(func.param_count + idx);
        }
        return .none;
    }

    // -- Instruction builders --

    /// Materialize an integer constant. The value is sign-extended to 64 bits
    /// in the emitted code.
    pub fn buildIntConst(self: *Builder, type_idx: TypeIdx, value: i64) !Value {
        const bits: u64 = @bitCast(value);
        return self.appendInstruction(.{
            .opcode = .iconst,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{ @truncate(bits), @truncate(bits >> 32) }),
        });
    }

    /// Materialize a floating-point constant.
    pub fn buildFloatConst(self: *Builder, type_idx: TypeIdx, value: f64) !Value {
        const bits: u64 = @bitCast(value);
        return self.appendInstruction(.{
            .opcode = .fconst,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{ @truncate(bits), @truncate(bits >> 32) }),
        });
    }

    fn buildBinOp(self: *Builder, opcode: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.appendInstruction(.{
            .opcode = opcode,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{ @intFromEnum(lhs), @intFromEnum(rhs) }),
        });
    }

    pub fn buildAdd(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.add, type_idx, lhs, rhs);
    }

    pub fn buildSub(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.sub, type_idx, lhs, rhs);
    }

    pub fn buildMul(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.mul, type_idx, lhs, rhs);
    }

    pub fn buildSDiv(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.sdiv, type_idx, lhs, rhs);
    }

    pub fn buildUDiv(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.udiv, type_idx, lhs, rhs);
    }

    pub fn buildSRem(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.srem, type_idx, lhs, rhs);
    }

    pub fn buildURem(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.urem, type_idx, lhs, rhs);
    }

    pub fn buildFAdd(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.fadd, type_idx, lhs, rhs);
    }

    pub fn buildFSub(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.fsub, type_idx, lhs, rhs);
    }

    pub fn buildFMul(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.fmul, type_idx, lhs, rhs);
    }

    pub fn buildFDiv(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.fdiv, type_idx, lhs, rhs);
    }

    pub fn buildAnd(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.and_op, type_idx, lhs, rhs);
    }

    pub fn buildOr(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.or_op, type_idx, lhs, rhs);
    }

    pub fn buildXor(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.xor_op, type_idx, lhs, rhs);
    }

    pub fn buildShl(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.shl, type_idx, lhs, rhs);
    }

    pub fn buildShr(self: *Builder, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(.shr, type_idx, lhs, rhs);
    }

    pub fn buildIcmp(self: *Builder, cond: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(cond, type_idx, lhs, rhs);
    }

    pub fn buildFCmp(self: *Builder, cond: Opcode, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value {
        return self.buildBinOp(cond, type_idx, lhs, rhs);
    }

    pub fn buildBr(self: *Builder, target: BasicBlockIdx) !Value {
        return self.appendInstruction(.{
            .opcode = .br,
            .type_idx = @enumFromInt(0),
            .operands = try self.appendOperands(&.{@intFromEnum(target)}),
        });
    }

    pub fn buildCondBr(self: *Builder, cond: Value, true_block: BasicBlockIdx, false_block: BasicBlockIdx) !Value {
        return self.appendInstruction(.{
            .opcode = .cond_br,
            .type_idx = @enumFromInt(0),
            .operands = try self.appendOperands(&.{ @intFromEnum(cond), @intFromEnum(true_block), @intFromEnum(false_block) }),
        });
    }

    pub fn buildRet(self: *Builder, val: Value) !Value {
        return self.appendInstruction(.{
            .opcode = .ret,
            .type_idx = @enumFromInt(0),
            .operands = try self.appendOperands(&.{@intFromEnum(val)}),
        });
    }

    pub fn buildRetVoid(self: *Builder) !Value {
        return self.appendInstruction(.{
            .opcode = .ret_void,
            .type_idx = @enumFromInt(0),
            .operands = try self.appendOperands(&.{}),
        });
    }

    pub fn buildCall(self: *Builder, func_idx: FunctionIdx, type_idx: TypeIdx, args: []const Value) !Value {
        var ops = std.ArrayList(u32).empty;
        defer ops.deinit(self.gpa);
        try ops.append(self.gpa, @intFromEnum(func_idx));
        for (args) |arg| {
            try ops.append(self.gpa, @intFromEnum(arg));
        }
        return self.appendInstruction(.{
            .opcode = .call,
            .type_idx = type_idx,
            .operands = try self.appendOperands(ops.items),
        });
    }

    /// Indirect call through a fn value (docs/semantics.md §6.4, R16c).
    ///
    /// `callee` must be a `function_value`-typed SSA value — the address of
    /// a `fn_value_size`-byte `{ fn_ptr, env_ptr }` record (see
    /// `buildFnValue`). At codegen, `env_ptr` becomes the callee's hidden
    /// argument 0 (the uniform env-first ABI, docs/semantics.md §6.2) and
    /// `args` are the visible arguments. `type_idx` is the call's return
    /// type.
    pub fn buildCallPtr(self: *Builder, type_idx: TypeIdx, callee: Value, args: []const Value) !Value {
        var ops = std.ArrayList(u32).empty;
        defer ops.deinit(self.gpa);
        try ops.append(self.gpa, @intFromEnum(callee));
        for (args) |arg| {
            try ops.append(self.gpa, @intFromEnum(arg));
        }
        return self.appendInstruction(.{
            .opcode = .call_ptr,
            .type_idx = type_idx,
            .operands = try self.appendOperands(ops.items),
        });
    }

    /// Materialize a fn value: the `fn_value_size`-byte `{ fn_ptr, env_ptr }`
    /// record (docs/semantics.md §3.3, R16b).
    ///
    /// The record is placed in the current frame (the default stack env
    /// placement); the produced value is the record's address. `type_idx`
    /// must be a `function_value` type. `fn_ptr` is an SSA value holding the
    /// callee's address; `env_ptr` is an SSA value holding the address of the
    /// captured-env record, or a null pointer for a plain fn reference
    /// (docs/semantics.md R3a).
    pub fn buildFnValue(self: *Builder, type_idx: TypeIdx, fn_ptr: Value, env_ptr: Value) !Value {
        const i64_ty = try self.module.addType(self.gpa, .{ .int = .{ .signed = true, .bits = 64 } });
        const i64_ptr_ty = try self.module.addType(self.gpa, .{ .pointer = .{ .elem = i64_ty } });
        const record = try self.buildAllocaBytes(type_idx, fn_value_size);
        _ = try self.buildStore(i64_ty, record, fn_ptr);
        const env_offset = try self.buildIntConst(i64_ty, 8);
        const env_slot = try self.buildPtrAdd(i64_ptr_ty, record, env_offset);
        _ = try self.buildStore(i64_ty, env_slot, env_ptr);
        return record;
    }

    /// Build a closure env record in the current frame (stack placement,
    /// docs/semantics.md §5.4, R10a): allocate a stack block sized for the
    /// captured set (`envRecordSize`) and copy each capture by value at its
    /// slot offset (docs/semantics.md §5.2, R8c). Returns the record's
    /// address, ready to pair with a lifted callee in `buildFnValue`.
    ///
    /// An empty capture set produces no record and returns `Value.none` —
    /// pair the fn value with a null env instead (docs/semantics.md §5.2,
    /// R8b). A `function_value` field is copied inline as its two words,
    /// so a captured closure shares nothing with the source record.
    pub fn buildEnvRecord(self: *Builder, fields: []const EnvField) !Value {
        if (fields.len == 0) return .none;

        const i64_ty = try self.module.addType(self.gpa, .{ .int = .{ .signed = true, .bits = 64 } });
        const i64_ptr_ty = try self.module.addType(self.gpa, .{ .pointer = .{ .elem = i64_ty } });

        var size: u32 = 0;
        for (fields) |f| size += envFieldSize(self.module, f.type_idx);
        const env = try self.buildAllocaBytes(i64_ptr_ty, size);

        var offset: u32 = 0;
        for (fields) |f| {
            const slot = if (offset == 0)
                env
            else
                try self.buildPtrAdd(i64_ptr_ty, env, try self.buildIntConst(i64_ty, offset));
            switch (self.module.getIrType(f.type_idx)) {
                .function_value => {
                    // The field value is the source record's address; copy
                    // both words (docs/semantics.md §6.4, R16d).
                    const word0 = try self.buildLoad(i64_ty, f.value);
                    _ = try self.buildStore(i64_ty, slot, word0);
                    const word1_off = try self.buildIntConst(i64_ty, offset + 8);
                    const src1 = try self.buildPtrAdd(i64_ptr_ty, f.value, word1_off);
                    const word1 = try self.buildLoad(i64_ty, src1);
                    const dst1 = try self.buildPtrAdd(i64_ptr_ty, env, word1_off);
                    _ = try self.buildStore(i64_ty, dst1, word1);
                },
                else => _ = try self.buildStore(f.type_idx, slot, f.value),
            }
            offset += envFieldSize(self.module, f.type_idx);
        }
        return env;
    }

    /// Declare an external C function (deduplicated by name) and return its
    /// index into `Module.externs`.
    pub fn addExtern(self: *Builder, name: []const u8) !u32 {
        for (self.module.externs.items, 0..) |ext, i| {
            if (std.mem.eql(u8, self.module.strings.get(ext.name), name)) {
                return @intCast(i);
            }
        }
        const name_ref = try self.module.strings.intern(self.gpa, name);
        try self.module.externs.append(self.gpa, .{ .name = name_ref });
        return @intCast(self.module.externs.items.len - 1);
    }

    /// Call an external C function by name. Does not produce an SSA value.
    pub fn buildExternCall(self: *Builder, name: []const u8, type_idx: TypeIdx, args: []const Value) !Value {
        const ext_idx = try self.addExtern(name);
        var ops = std.ArrayList(u32).empty;
        defer ops.deinit(self.gpa);
        try ops.append(self.gpa, ext_idx);
        for (args) |arg| {
            try ops.append(self.gpa, @intFromEnum(arg));
        }
        return self.appendInstruction(.{
            .opcode = .extern_call,
            .type_idx = type_idx,
            .operands = try self.appendOperands(ops.items),
        });
    }

    pub fn buildAlloca(self: *Builder, type_idx: TypeIdx) !Value {
        return self.appendInstruction(.{
            .opcode = .alloca,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{}),
        });
    }

    /// Allocate `size_bytes` of stack space, aligned to 8 bytes.
    ///
    /// Returns a pointer to the start of the block. Multiple allocas get
    /// disjoint frame regions, so this is safe for aggregates (structs,
    /// `[len][ptr]` string representations, etc.) that do not fit in a
    /// single 8-byte slot.
    pub fn buildAllocaBytes(self: *Builder, type_idx: TypeIdx, size_bytes: u32) !Value {
        return self.appendInstruction(.{
            .opcode = .alloca,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{size_bytes}),
        });
    }

    pub fn buildLoad(self: *Builder, type_idx: TypeIdx, ptr: Value) !Value {
        return self.appendInstruction(.{
            .opcode = .load,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{@intFromEnum(ptr)}),
        });
    }

    pub fn buildStore(self: *Builder, type_idx: TypeIdx, ptr: Value, val: Value) !Value {
        return self.appendInstruction(.{
            .opcode = .store,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{ @intFromEnum(ptr), @intFromEnum(val) }),
        });
    }

    pub fn buildPhi(self: *Builder, type_idx: TypeIdx, incoming: []const PhiIncoming) !Value {
        var ops = std.ArrayList(u32).empty;
        defer ops.deinit(self.gpa);
        for (incoming) |inc| {
            try ops.append(self.gpa, @intFromEnum(inc.value));
            try ops.append(self.gpa, @intFromEnum(inc.block));
        }
        return self.appendInstruction(.{
            .opcode = .phi,
            .type_idx = type_idx,
            .operands = try self.appendOperands(ops.items),
        });
    }

    /// Compute `ptr + offset` (unscaled byte offset).
    pub fn buildPtrAdd(self: *Builder, type_idx: TypeIdx, ptr: Value, offset: Value) !Value {
        return self.buildBinOp(.ptr_add, type_idx, ptr, offset);
    }

    /// Heap-allocate `size` bytes. Returns a pointer to the allocation.
    pub fn buildMalloc(self: *Builder, type_idx: TypeIdx, size: Value) !Value {
        return self.appendInstruction(.{
            .opcode = .malloc,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{@intFromEnum(size)}),
        });
    }

    /// Take the address of a module-level global.
    pub fn buildGlobalAddr(self: *Builder, type_idx: TypeIdx, global: GlobalIdx) !Value {
        return self.appendInstruction(.{
            .opcode = .global_addr,
            .type_idx = type_idx,
            .operands = try self.appendOperands(&.{@intFromEnum(global)}),
        });
    }
};

pub const PhiIncoming = struct {
    value: Value,
    block: BasicBlockIdx,
};

// ============================================================================
// Textual IR Printer
// ============================================================================

pub fn printModule(module: *Module, writer: anytype) !void {
    // `writer` is a pointer to an std.Io.Writer (or compatible) whose methods
    // mutate the writer through the pointer.
    const w = writer;
    for (module.externs.items) |ext| {
        try w.print("extern {s}\n", .{module.strings.get(ext.name)});
    }

    for (module.globals.items) |global| {
        const name = module.strings.get(global.name);
        switch (global.kind) {
            .string => |data| {
                try w.print("global @{s} = string \"", .{name});
                const bytes = module.strings.get(data);
                for (bytes) |byte| {
                    switch (byte) {
                        '"' => try w.writeAll("\\\""),
                        '\\' => try w.writeAll("\\\\"),
                        else => try w.writeByte(byte),
                    }
                }
                try w.print("\"\n", .{});
            },
            .fn_array => |funcs| {
                try w.print("global @{s} = fn_array [", .{name});
                for (funcs, 0..) |func, i| {
                    if (i > 0) try w.print(", ", .{});
                    try w.print("@fn{d}", .{func});
                }
                try w.print("]\n", .{});
            },
        }
    }

    for (module.functions.items) |func| {
        const name = module.strings.get(func.name);
        try w.print("fn @{s}() {{\n", .{name});

        for (func.blocks.items, 0..) |block, block_idx| {
            try w.print("  bb{}:\n", .{block_idx});

            const start = @intFromEnum(block.first_inst);
            const end = start + block.inst_count;
            for (func.instructions.items[start..end], 0..) |inst, i| {
                const inst_idx = start + i;
                try w.print("    ", .{});
                if (inst.producesValue()) {
                    try w.print("%{d} = ", .{func.param_count + inst_idx});
                }
                try printInstruction(module, func, inst, w);
                try w.print("\n", .{});
            }
        }

        try w.print("}}\n\n", .{});
    }
}

fn printInstruction(module: *Module, func: Function, inst: Instruction, writer: anytype) !void {
    const w = writer;
    const ops = func.getOperands(inst.operands);
    switch (inst.opcode) {
        .iconst => try w.print("iconst {d}", .{@as(i64, @bitCast((@as(u64, ops[1]) << 32) | ops[0]))}),
        .fconst => try w.print("fconst {d}", .{@as(f64, @bitCast((@as(u64, ops[1]) << 32) | ops[0]))}),
        .add => try w.print("add %{d}, %{d}", .{ ops[0], ops[1] }),
        .sub => try w.print("sub %{d}, %{d}", .{ ops[0], ops[1] }),
        .mul => try w.print("mul %{d}, %{d}", .{ ops[0], ops[1] }),
        .sdiv => try w.print("sdiv %{d}, %{d}", .{ ops[0], ops[1] }),
        .udiv => try w.print("udiv %{d}, %{d}", .{ ops[0], ops[1] }),
        .srem => try w.print("srem %{d}, %{d}", .{ ops[0], ops[1] }),
        .urem => try w.print("urem %{d}, %{d}", .{ ops[0], ops[1] }),
        .fadd => try w.print("fadd %{d}, %{d}", .{ ops[0], ops[1] }),
        .fsub => try w.print("fsub %{d}, %{d}", .{ ops[0], ops[1] }),
        .fmul => try w.print("fmul %{d}, %{d}", .{ ops[0], ops[1] }),
        .fdiv => try w.print("fdiv %{d}, %{d}", .{ ops[0], ops[1] }),
        .and_op => try w.print("and %{d}, %{d}", .{ ops[0], ops[1] }),
        .or_op => try w.print("or %{d}, %{d}", .{ ops[0], ops[1] }),
        .xor_op => try w.print("xor %{d}, %{d}", .{ ops[0], ops[1] }),
        .shl => try w.print("shl %{d}, %{d}", .{ ops[0], ops[1] }),
        .shr => try w.print("shr %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_eq => try w.print("icmp eq %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ne => try w.print("icmp ne %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_slt => try w.print("icmp slt %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_sle => try w.print("icmp sle %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_sgt => try w.print("icmp sgt %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_sge => try w.print("icmp sge %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ult => try w.print("icmp ult %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ule => try w.print("icmp ule %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_ugt => try w.print("icmp ugt %{d}, %{d}", .{ ops[0], ops[1] }),
        .icmp_uge => try w.print("icmp uge %{d}, %{d}", .{ ops[0], ops[1] }),
        .fcmp_oeq => try w.print("fcmp oeq %{d}, %{d}", .{ ops[0], ops[1] }),
        .fcmp_one => try w.print("fcmp one %{d}, %{d}", .{ ops[0], ops[1] }),
        .fcmp_olt => try w.print("fcmp olt %{d}, %{d}", .{ ops[0], ops[1] }),
        .fcmp_ole => try w.print("fcmp ole %{d}, %{d}", .{ ops[0], ops[1] }),
        .fcmp_ogt => try w.print("fcmp ogt %{d}, %{d}", .{ ops[0], ops[1] }),
        .fcmp_oge => try w.print("fcmp oge %{d}, %{d}", .{ ops[0], ops[1] }),
        .br => try w.print("br bb{d}", .{ops[0]}),
        .cond_br => try w.print("cond_br %{d}, bb{d}, bb{d}", .{ ops[0], ops[1], ops[2] }),
        .ret => try w.print("ret %{d}", .{ops[0]}),
        .ret_void => try w.print("ret_void", .{}),
        .call => {
            try w.print("call @fn{d}(", .{ops[0]});
            for (ops[1..], 0..) |arg, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print("%{d}", .{arg});
            }
            try w.print(")", .{});
        },
        .call_ptr => {
            try w.print("call_ptr %{d}(", .{ops[0]});
            for (ops[1..], 0..) |arg, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print("%{d}", .{arg});
            }
            try w.print(")", .{});
        },
        .extern_call => {
            const ext_name = module.strings.get(module.externs.items[ops[0]].name);
            try w.print("extern_call {s}(", .{ext_name});
            for (ops[1..], 0..) |arg, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print("%{d}", .{arg});
            }
            try w.print(")", .{});
        },
        .ptr_add => try w.print("ptr_add %{d}, %{d}", .{ ops[0], ops[1] }),
        .malloc => try w.print("malloc %{d}", .{ops[0]}),
        .global_addr => {
            const gname = module.strings.get(module.globals.items[ops[0]].name);
            try w.print("global_addr @{s}", .{gname});
        },
        .alloca => {
            if (ops.len == 0) {
                try w.print("alloca", .{});
            } else {
                try w.print("alloca {d}", .{ops[0]});
            }
        },
        .load => try w.print("load %{d}", .{ops[0]}),
        .store => try w.print("store %{d}, %{d}", .{ ops[0], ops[1] }),
        .phi => {
            try w.print("phi ", .{});
            var i: usize = 0;
            while (i + 1 < ops.len) : (i += 2) {
                try w.print("[ %{d}, bb{d} ] ", .{ ops[i], ops[i + 1] });
            }
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "basic module construction" {
    var module = Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = Builder.init(std.testing.allocator, &module);
    _ = try builder.addVoidType();
    const i32_type = try builder.addIntType(false, 32);

    const func = try builder.addFunction("main", i32_type, 0);
    builder.setCurrentFunction(func);

    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    _ = try builder.buildRet(@enumFromInt(0));

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.functions.items[0].blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.functions.items[0].instructions.items.len);
}

test "fibonacci construction" {
    var module = Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = Builder.init(std.testing.allocator, &module);
    const i32_type = try builder.addIntType(true, 32);

    const fib = try builder.addFunction("fib", i32_type, 1);
    builder.setCurrentFunction(fib);

    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    // %cond = icmp sle %n, 1
    const n_param = @as(Value, @enumFromInt(0));
    const one = @as(Value, @enumFromInt(1));
    _ = one;
    const cond = try builder.buildIcmp(.icmp_sle, i32_type, n_param, @enumFromInt(0));

    const base = try builder.appendBlock();
    const recurse = try builder.appendBlock();
    _ = try builder.buildCondBr(cond, base, recurse);

    builder.setCurrentBlock(base);
    _ = try builder.buildRet(n_param);

    builder.setCurrentBlock(recurse);
    _ = try builder.buildRet(n_param);

    try std.testing.expectEqual(@as(usize, 3), module.functions.items[0].blocks.items.len);
}

test "extended opcodes and globals" {
    var module = Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = Builder.init(std.testing.allocator, &module);
    const void_ty = try builder.addVoidType();
    const i64_ty = try builder.addIntType(true, 64);
    const f64_ty = try builder.addFloatType(.f64);
    const ptr_ty = try builder.addPointerType(i64_ty);

    const helper = try builder.addFunction("helper", void_ty, 0);
    builder.setCurrentFunction(helper);
    const h_entry = try builder.appendBlock();
    builder.setCurrentBlock(h_entry);
    _ = try builder.buildRetVoid();

    const str_global = try builder.addStringGlobal("greeting", "hello");
    _ = try builder.addFnArrayGlobal("vtable", &.{helper});

    const main = try builder.addFunction("main", i64_ty, 3);
    builder.setCurrentFunction(main);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    const a = @as(Value, @enumFromInt(0));
    const b = @as(Value, @enumFromInt(1));
    const callee_addr = @as(Value, @enumFromInt(2));

    _ = try builder.buildIntConst(i64_ty, 10);
    _ = try builder.buildFloatConst(f64_ty, 1.5);
    _ = try builder.buildSRem(i64_ty, a, b);
    _ = try builder.buildURem(i64_ty, a, b);
    _ = try builder.buildFAdd(f64_ty, a, b);
    _ = try builder.buildFSub(f64_ty, a, b);
    _ = try builder.buildFMul(f64_ty, a, b);
    _ = try builder.buildFDiv(f64_ty, a, b);
    _ = try builder.buildFCmp(.fcmp_olt, f64_ty, a, b);
    _ = try builder.buildFCmp(.fcmp_oge, f64_ty, a, b);
    _ = try builder.buildPtrAdd(ptr_ty, a, b);
    _ = try builder.buildMalloc(ptr_ty, a);
    _ = try builder.buildGlobalAddr(ptr_ty, str_global);
    // Indirect call through a fn value (R16c): pair the callee address with
    // a null env, then call through the record.
    const sig = try builder.addFunctionType(i64_ty, &.{ i64_ty, i64_ty });
    const fv_ty = try builder.addFunctionValueType(sig);
    const null_env = try builder.buildIntConst(i64_ty, 0);
    const fv = try builder.buildFnValue(fv_ty, callee_addr, null_env);
    _ = try builder.buildCallPtr(i64_ty, fv, &.{ a, b });
    _ = try builder.buildExternCall("puts", void_ty, &.{a});
    _ = try builder.buildRet(a);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printModule(&module, &w);
    const text = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, text, "global @greeting = string \"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global @vtable = fn_array [@fn0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret_void") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "iconst 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fconst 1.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "srem %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "urem %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fadd %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fsub %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fmul %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fdiv %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fcmp olt %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fcmp oge %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "malloc %0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global_addr @greeting") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr %17(%0, %1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extern puts") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extern_call puts(%0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %0") != null);
}

test "function value type and record materialization" {
    var module = Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = Builder.init(std.testing.allocator, &module);
    const i64_ty = try builder.addIntType(true, 64);

    // Visible signature of the callee: fn(i64) -> i64.
    const sig = try builder.addFunctionType(i64_ty, &.{i64_ty});
    const fv_ty = try builder.addFunctionValueType(sig);

    try std.testing.expectEqual(@as(u32, 16), fn_value_size);
    try std.testing.expectEqual(
        IrType{ .function_value = .{ .signature = sig } },
        module.getIrType(fv_ty),
    );

    // Lifted closure body reading its capture through env + 0:
    //   fn __closure_main_0(env: ptr, x: i64) -> i64 { load(env) + x }
    const lifted = try builder.addFunction("__closure_main_0", i64_ty, 2);
    builder.setCurrentFunction(lifted);
    const l_entry = try builder.appendBlock();
    builder.setCurrentBlock(l_entry);
    const env_param = @as(Value, @enumFromInt(0));
    const x_param = @as(Value, @enumFromInt(1));
    const captured = try builder.buildLoad(i64_ty, env_param);
    _ = try builder.buildRet(try builder.buildAdd(i64_ty, captured, x_param));

    // Creation site: the env record holds the by-value capture, then the fn
    // value pairs the lifted callee's address with the env record's address.
    const make = try builder.addFunction("make_closure", fv_ty, 1);
    builder.setCurrentFunction(make);
    const m_entry = try builder.appendBlock();
    builder.setCurrentBlock(m_entry);
    const fn_ptr_param = @as(Value, @enumFromInt(0)); // callee address

    const env = try builder.buildAllocaBytes(i64_ty, 8);
    const capture_val = try builder.buildIntConst(i64_ty, 42);
    _ = try builder.buildStore(i64_ty, env, capture_val);
    const fv = try builder.buildFnValue(fv_ty, fn_ptr_param, env);
    _ = try builder.buildRet(fv);

    // Creation site: env alloca + capture store, then the five instructions
    // buildFnValue expands to (alloca 16, store fn_ptr, iconst 8, ptr_add,
    // store env_ptr), then ret.
    try std.testing.expectEqual(@as(usize, 9), module.functions.items[1].instructions.items.len);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printModule(&module, &w);
    const text = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %4") != null);
}

test "call through fn value with captured env record" {
    var module = Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = Builder.init(std.testing.allocator, &module);
    const i64_ty = try builder.addIntType(true, 64);

    const sig = try builder.addFunctionType(i64_ty, &.{i64_ty});
    const fv_ty = try builder.addFunctionValueType(sig);

    // Env layout (R8a): one 8-byte slot per scalar capture, 16 bytes for an
    // inline fn-value capture.
    try std.testing.expectEqual(@as(u32, 8), envFieldSize(&module, i64_ty));
    try std.testing.expectEqual(@as(u32, 16), envFieldSize(&module, fv_ty));
    try std.testing.expectEqual(
        @as(u32, 32),
        envRecordSize(&module, &.{ i64_ty, i64_ty, fv_ty }),
    );

    // Lifted closure: fn __closure_main_0(env, x) { load(env) + x }
    const lifted = try builder.addFunction("__closure_main_0", i64_ty, 2);
    builder.setCurrentFunction(lifted);
    const l_entry = try builder.appendBlock();
    builder.setCurrentBlock(l_entry);
    const env_param = @as(Value, @enumFromInt(0));
    const x_param = @as(Value, @enumFromInt(1));
    const captured = try builder.buildLoad(i64_ty, env_param);
    _ = try builder.buildRet(try builder.buildAdd(i64_ty, captured, x_param));

    // Creation + call site: env = buildEnvRecord({40}); fv = (fn_addr, env);
    // call_ptr fv(x). The callee address arrives as a parameter (there is no
    // fn-address op yet).
    const make = try builder.addFunction("make", i64_ty, 2);
    builder.setCurrentFunction(make);
    const m_entry = try builder.appendBlock();
    builder.setCurrentBlock(m_entry);
    const fn_addr_param = @as(Value, @enumFromInt(0));
    const x2 = @as(Value, @enumFromInt(1));

    const forty = try builder.buildIntConst(i64_ty, 40);
    const env = try builder.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = forty }});
    const fv = try builder.buildFnValue(fv_ty, fn_addr_param, env);
    _ = try builder.buildCallPtr(i64_ty, fv, &.{x2});

    // iconst, env alloca + store, then buildFnValue's five instructions,
    // then the indirect call.
    try std.testing.expectEqual(@as(usize, 9), module.functions.items[1].instructions.items.len);

    // Empty capture set: no record, null env (R8b).
    const none_env = try builder.buildEnvRecord(&.{});
    try std.testing.expectEqual(Value.none, none_env);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printModule(&module, &w);
    const text = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr %5(%1)") != null);
}
