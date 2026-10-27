# Tungsten Frontend API Reference

The `api` module is the recommended interface for frontend compilers written in
Zig. It wraps the low-level IR builder behind a single `Context` object that owns
all module state and provides methods for type creation, function definition,
instruction building, and code emission.

```zig
const tungsten = @import("Tungsten");
const api = tungsten.api;
```

---

## Table of Contents

1. [Architecture](#architecture)
2. [Quick Start](#quick-start)
3. [Lifecycle](#lifecycle)
4. [Type System](#type-system)
5. [Functions](#functions)
6. [Basic Blocks](#basic-blocks)
7. [Parameter Access](#parameter-access)
8. [Instruction Building](#instruction-building)
9. [Output](#output)
10. [Re-exported Types](#re-exported-types)
11. [Design Notes](#design-notes)

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Context                       │
│                                                 │
│  ┌──────────────┐   ┌────────────────────────┐  │
│  │    Module    │◄──│       Builder          │  │
│  │              │   │                        │  │
│  │  functions   │   │  current_func          │  │
│  │  types       │   │  current_block         │  │
│  │  strings     │   │                        │  │
│  └──────────────┘   └────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

- **Context** — heap-allocated top-level object. Owns the Module and Builder.
  All frontend operations go through this.
- **Module** — flat storage for functions, types, and the string pool.
  Accessible via `ctx.module` for advanced use cases.
- **Builder** — tracks the current insertion point and appends instructions.
  Accessible via `ctx.builder`.

The Context is heap-allocated so that the Builder's internal pointer to the
Module remains stable for the lifetime of the Context.

---

## Quick Start

```zig
const std = @import("std");
const tungsten = @import("Tungsten");
const api = tungsten.api;

pub fn main() !void {
    // 1. Create context
    var ctx = try api.Context.init(std.heap.page_allocator);
    defer ctx.deinit();

    // 2. Define types
    const i32_ty = try ctx.intType(true, 32);

    // 3. Create function: int add(int a, int b)
    const func = try ctx.addFunction("add", i32_ty, 2);
    ctx.setCurrentFunction(func);

    // 4. Build the entry block
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);
    const sum = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildRet(sum);

    // 5. Emit code
    const asm_text = try ctx.emitAssembly();
    defer ctx.gpa.free(asm_text);

    // Or print textual IR:
    try ctx.print(std.io.getStdOut().writer());
}
```

---

## Lifecycle

### `Context.init`

```zig
pub fn init(gpa: Allocator) !*Context
```

Create a new Tungsten context. Allocates the context on the heap so that
internal pointers remain stable. Returns a pointer that must be freed via
`deinit`.

### `Context.deinit`

```zig
pub fn deinit(self: *Context) void
```

Destroy the context, free the IR module, and release all associated memory.

**Usage:**

```zig
var ctx = try api.Context.init(allocator);
defer ctx.deinit(); // must be called exactly once
```

---

## Type System

All type-creation methods return a `TypeIdx` — a compact 4-byte handle into
the module's type table. Types are deduplicated implicitly (each call appends
a new entry; use `getType` to inspect).

### `voidType`

```zig
pub fn voidType(self: *Context) !TypeIdx
```

Create a `void` type.

### `boolType`

```zig
pub fn boolType(self: *Context) !TypeIdx
```

Create a `bool` type (1-bit).

### `intType`

```zig
pub fn intType(self: *Context, signed: bool, bits: u16) !TypeIdx
```

Create an integer type with the given signedness and bit width.

| Example | signed | bits | Description |
|---------|--------|------|-------------|
| `intType(true, 32)` | true | 32 | Signed 32-bit integer (`i32`) |
| `intType(false, 8)` | false | 8 | Unsigned 8-bit integer (`u8`) |
| `intType(true, 64)` | true | 64 | Signed 64-bit integer (`i64`) |

### `floatType`

```zig
pub fn floatType(self: *Context, ft: FloatType) !TypeIdx
```

Create a floating-point type. `ft` is one of:

| Value | Bits | Description |
|-------|------|-------------|
| `.f16` | 16 | Half precision |
| `.f32` | 32 | Single precision |
| `.f64` | 64 | Double precision |

### `ptrType`

```zig
pub fn ptrType(self: *Context, elem: TypeIdx) !TypeIdx
```

Create a pointer type pointing to `elem`.

```zig
const i32_ty = try ctx.intType(true, 32);
const i32_ptr = try ctx.ptrType(i32_ty);  // i32*
```

### `funcType`

```zig
pub fn funcType(self: *Context, ret: TypeIdx, param_types: []const TypeIdx) !TypeIdx
```

Create a function type. This is used when making function calls, not when
defining functions (use `addFunction` for that).

```zig
const i32_ty = try ctx.intType(true, 32);
const fn_ty = try ctx.funcType(i32_ty, &.{ i32_ty, i32_ty });
// fn(i32, i32) -> i32
```

### `fnValueType`

```zig
pub fn fnValueType(self: *Context, signature: TypeIdx) !TypeIdx
```

Create a fn-value type — the type of a first-class function value. The
runtime representation is the `fn_value_size`-byte (16) record
`{ fn_ptr: u64, env_ptr: u64 }` (see `docs/semantics.md` §3.3).

- `signature` — a `funcType` describing the *visible* callee signature. The
  hidden env parameter (see `buildCallPtr`) is **not** part of it.

```zig
const i64_ty = try ctx.intType(true, 64);
const sig = try ctx.funcType(i64_ty, &.{i64_ty});  // fn(i64) -> i64
const fv_ty = try ctx.fnValueType(sig);
```

### `getType`

```zig
pub fn getType(self: *Context, idx: TypeIdx) IrType
```

Look up a type by its index. Returns the `IrType` union.

### `getTypeCount`

```zig
pub fn getTypeCount(self: *Context) usize
```

Return the number of types registered in the module.

---

## Functions

### `addFunction`

```zig
pub fn addFunction(
    self: *Context,
    name: []const u8,
    return_type: TypeIdx,
    param_count: u32,
) !FunctionIdx
```

Add a new function to the module. Returns a `FunctionIdx` handle.

After creation, call `setCurrentFunction` to begin building the function body.

```zig
const func = try ctx.addFunction("my_func", i32_ty, 2);
ctx.setCurrentFunction(func);
```

### `setCurrentFunction`

```zig
pub fn setCurrentFunction(self: *Context, func: FunctionIdx) void
```

Set the current function for subsequent block and instruction creation.
Resets the current block to `null` — call `appendBlock` + `setCurrentBlock`
before inserting instructions.

### `getFunction`

```zig
pub fn getFunction(self: *Context, idx: FunctionIdx) *ir.Function
```

Get a mutable reference to the underlying `Function` struct. Useful for
inspecting blocks, instructions, and extra data directly.

### `getFunctionCount`

```zig
pub fn getFunctionCount(self: *Context) usize
```

Return the number of functions in the module.

### `getFunctionName`

```zig
pub fn getFunctionName(self: *Context, idx: FunctionIdx) []const u8
```

Return the name of a function as a string slice.

### `getBlockCountIn`

```zig
pub fn getBlockCountIn(self: *Context, idx: FunctionIdx) usize
```

Return the number of basic blocks in the given function.

### `getInstructionCountIn`

```zig
pub fn getInstructionCountIn(self: *Context, idx: FunctionIdx) usize
```

Return the total number of instructions in the given function (across all
basic blocks).

---

## Basic Blocks

### `appendBlock`

```zig
pub fn appendBlock(self: *Context) !BasicBlockIdx
```

Append a new basic block to the **current function**. Panics if no current
function has been set via `setCurrentFunction`.

### `setCurrentBlock`

```zig
pub fn setCurrentBlock(self: *Context, block: BasicBlockIdx) void
```

Set the current insertion point to the end of the given basic block. All
subsequent `build*` calls will append instructions to this block.

---

## Parameter Access

### `getParam`

```zig
pub fn getParam(self: *Context, index: u32) Value
```

Get the SSA value handle for a function parameter. Parameters are numbered
from 0. The Nth parameter of the current function is `getParam(N)`.

Parameters implicitly exist at the start of a function — no instruction is
created for them. A function with 2 parameters has `Value(0)` and `Value(1)`
available immediately after entering the first block.

```zig
const func = try ctx.addFunction("add", i32_ty, 2);
ctx.setCurrentFunction(func);
const entry = try ctx.appendBlock();
ctx.setCurrentBlock(entry);

const a = ctx.getParam(0);  // first parameter
const b = ctx.getParam(1);  // second parameter
```

---

## Instruction Building

All instruction-building methods:
- Return `!Value` — the SSA value produced by the instruction (or `Value.none`
  for side-effect-only instructions like `ret`, `store`, `br`).
- Must be called after `setCurrentFunction` and `setCurrentBlock` have been set.
- Append the instruction to the end of the current basic block.

### Arithmetic

#### `buildAdd`

```zig
pub fn buildAdd(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = add %lhs, %rhs` — integer addition.

#### `buildSub`

```zig
pub fn buildSub(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = sub %lhs, %rhs` — integer subtraction.

#### `buildMul`

```zig
pub fn buildMul(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = mul %lhs, %rhs` — integer multiplication.

#### `buildSDiv`

```zig
pub fn buildSDiv(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = sdiv %lhs, %rhs` — signed integer division.

#### `buildUDiv`

```zig
pub fn buildUDiv(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = udiv %lhs, %rhs` — unsigned integer division.

### Bitwise

#### `buildAnd`

```zig
pub fn buildAnd(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = and %lhs, %rhs` — bitwise AND.

#### `buildOr`

```zig
pub fn buildOr(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = or %lhs, %rhs` — bitwise OR.

#### `buildXor`

```zig
pub fn buildXor(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = xor %lhs, %rhs` — bitwise XOR.

#### `buildShl`

```zig
pub fn buildShl(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = shl %lhs, %rhs` — shift left.

#### `buildShr`

```zig
pub fn buildShr(self: *Context, type_idx: TypeIdx, lhs: Value, rhs: Value) !Value
```

`%r = shr %lhs, %rhs` — shift right.

### Comparison

#### `buildIcmp`

```zig
pub fn buildIcmp(
    self: *Context,
    cond: Opcode,
    type_idx: TypeIdx,
    lhs: Value,
    rhs: Value,
) !Value
```

`%r = icmp <cond> %lhs, %rhs` — integer comparison. Produces a boolean
result (0 or 1).

`cond` must be one of the `icmp_*` opcodes:

| Opcode | Description |
|--------|-------------|
| `.icmp_eq` | Equal |
| `.icmp_ne` | Not equal |
| `.icmp_slt` | Signed less than |
| `.icmp_sle` | Signed less or equal |
| `.icmp_sgt` | Signed greater than |
| `.icmp_sge` | Signed greater or equal |
| `.icmp_ult` | Unsigned less than |
| `.icmp_ule` | Unsigned less or equal |
| `.icmp_ugt` | Unsigned greater than |
| `.icmp_uge` | Unsigned greater or equal |

```zig
const cond = try ctx.buildIcmp(.icmp_sle, i32_ty, a, b);
```

### Control Flow

#### `buildBr`

```zig
pub fn buildBr(self: *Context, target: BasicBlockIdx) !Value
```

`br %target` — unconditional branch to the target basic block.

#### `buildCondBr`

```zig
pub fn buildCondBr(
    self: *Context,
    cond: Value,
    true_block: BasicBlockIdx,
    false_block: BasicBlockIdx,
) !Value
```

`cond_br %cond, %true_block, %false_block` — branch to `true_block` if
`cond` is nonzero, otherwise to `false_block`.

#### `buildRet`

```zig
pub fn buildRet(self: *Context, val: Value) !Value
```

`ret %val` — return the value from the current function.

### Function Calls

#### `buildCall`

```zig
pub fn buildCall(
    self: *Context,
    func: FunctionIdx,
    type_idx: TypeIdx,
    args: []const Value,
) !Value
```

`%r = call @func(arg0, arg1, ...)` — call a function with the given arguments.

- `func` — the function to call.
- `type_idx` — the return type of the call.
- `args` — slice of argument values.

```zig
const callee = try ctx.addFunction("add", i32_ty, 2);
// ...
const result = try ctx.buildCall(callee, i32_ty, &.{ a, b });
```

#### `buildCallPtr`

```zig
pub fn buildCallPtr(self: *Context, type_idx: TypeIdx, callee: Value, args: []const Value) !Value
```

`%r = call_ptr %callee(args...)` — indirect call through a fn value.

- `callee` — an SSA value of a `fnValueType` type: the **address of a
  `{ fn_ptr, env_ptr }` record** (produced by `buildFnValue`).
- `type_idx` — the return type of the call.
- `args` — the *visible* arguments.

At codegen, the callee's `fn_ptr` is loaded from record+0 and its `env_ptr`
from record+8; `env_ptr` is passed as the callee's **hidden argument 0** (the
uniform env-first ABI, see `docs/semantics.md` §6.2) and the call goes
through `fn_ptr` with the visible args shifted by one slot.

```zig
const fv = try ctx.buildFnValue(fv_ty, fn_addr, env);
const r = try ctx.buildCallPtr(i64_ty, fv, &.{ x });
```

#### `buildFnValue`

```zig
pub fn buildFnValue(self: *Context, type_idx: TypeIdx, fn_ptr: Value, env_ptr: Value) !Value
```

Materialize a fn value: allocate a `fn_value_size`-byte (16) record in the
current frame, store `fn_ptr` at offset 0 and `env_ptr` at offset 8, and
produce the record's address.

- `type_idx` — a `fnValueType` type.
- `fn_ptr` — an SSA value holding the lifted callee's address.
- `env_ptr` — an SSA value holding the captured-env record's address (from
  `buildEnvRecord`), or a null pointer for a plain fn reference
  (`docs/semantics.md` R3a).

```zig
const null_env = try ctx.buildIntConst(i64_ty, 0);
const fv = try ctx.buildFnValue(fv_ty, fn_addr, null_env);
```

#### `buildFuncAddr`

```zig
pub fn buildFuncAddr(self: *Context, type_idx: TypeIdx, func: FunctionIdx) !Value
```

`func_addr @func` — materialize the address of a module-level function as an
SSA value (emitted as `lea rax, [rel _func]`).

This is how a lifted closure body is paired with `buildFnValue`: take the
callee's address, build a `{ fn_ptr, env_ptr }` record around it, then
`buildCallPtr` through that record.

```zig
const lifted = try ctx.addFunction("__closure_0", i64_ty, 2);
// ...
const fn_addr = try ctx.buildFuncAddr(i64_ty, lifted);
const env = try ctx.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = captured }});
const fv = try ctx.buildFnValue(fv_ty, fn_addr, env);
const r = try ctx.buildCallPtr(i64_ty, fv, &.{ x });
```

### Closure Environments

#### `EnvField`

```zig
pub const EnvField = struct {
    type_idx: TypeIdx,
    value: Value,
};
```

One captured slot of a closure env record: the captured value's type and the
SSA value to copy into the record at creation time. Captures are by value
(`docs/semantics.md` §5.2, R8c).

#### `envRecordSize`

```zig
pub fn envRecordSize(self: *Context, field_types: []const TypeIdx) u32
```

Byte size of a closure env record holding the given captured field types in
declaration order (`docs/semantics.md` §5.2, R8a). Every capture occupies
one 8-byte slot, except a `function_value` capture, which stores its 16-byte
record inline.

#### `buildEnvRecord`

```zig
pub fn buildEnvRecord(self: *Context, fields: []const EnvField) !Value
```

Build a closure env record in the current frame (the default stack
placement, `docs/semantics.md` §5.4): allocate a stack block sized for the
captured set and copy each capture by value at its slot offset. Returns the
record's address, ready to pair with a lifted callee in `buildFnValue`.

An empty capture set produces no record and returns `Value.none` — pair the
fn value with a null env instead (`docs/semantics.md` R8b).

```zig
const captured = try ctx.buildIntConst(i64_ty, 40);
const env = try ctx.buildEnvRecord(&.{ .{ .type_idx = i64_ty, .value = captured } });
const fv = try ctx.buildFnValue(fv_ty, fn_addr, env);
const r = try ctx.buildCallPtr(i64_ty, fv, &.{ x });
```

### Memory

#### `buildAlloca`

```zig
pub fn buildAlloca(self: *Context, type_idx: TypeIdx) !Value
```

`%r = alloca` — allocate stack space for the given type. Returns a pointer
value.

```zig
const ptr = try ctx.buildAlloca(i32_ty);
```

#### `buildLoad`

```zig
pub fn buildLoad(self: *Context, type_idx: TypeIdx, ptr: Value) !Value
```

`%r = load %ptr` — load a value of `type_idx` from the pointer.

#### `buildStore`

```zig
pub fn buildStore(self: *Context, type_idx: TypeIdx, ptr: Value, val: Value) !Value
```

`store %ptr, %val` — store `val` (of `type_idx`) through the pointer.

### SSA

#### `buildPhi`

```zig
pub fn buildPhi(
    self: *Context,
    type_idx: TypeIdx,
    incoming: []const PhiIncoming,
) !Value
```

`%r = phi [ %val, bb ] ...` — SSA phi node. Each entry in `incoming`
specifies a value and the basic block it comes from.

```zig
const phi_val = try ctx.buildPhi(i32_ty, &.{
    .{ .value = val_from_entry, .block = entry_block },
    .{ .value = val_from_loop, .block = loop_block },
});
```

---

## Output

### `print`

```zig
pub fn print(self: *Context, writer: anytype) !void
```

Print the module's textual IR to `writer`. Useful for debugging.

```zig
try ctx.print(std.io.getStdOut().writer());
```

### `emitAssembly`

```zig
pub fn emitAssembly(self: *Context) ![]u8
```

Emit x86-64 NASM assembly for the entire module. Returns an allocated byte
slice that **the caller must free** with `ctx.gpa.free(result)`.

```zig
const asm_text = try ctx.emitAssembly();
defer ctx.gpa.free(asm_text);
```

---

## Re-exported Types

The `api` module re-exports all handle types from `ir` so that frontends
don't need to import `ir.zig` directly:

| Type | Description |
|------|-------------|
| `Value` | SSA value handle (4-byte `enum(u32)`) |
| `TypeIdx` | Type table index |
| `FunctionIdx` | Function array index |
| `BasicBlockIdx` | Basic block array index |
| `Opcode` | Instruction opcode enum |
| `FloatType` | Float type variants (`.f16`, `.f32`, `.f64`) |
| `IrType` | Type union (`void`, `bool_type`, `int`, `float`, `pointer`, `function`, `function_value`) |
| `IntType` | Integer type struct (`signed`, `bits`) |
| `PointerType` | Pointer type struct (`elem`) |
| `FunctionType` | Function type struct (`return_type`, `param_types`) |
| `FunctionValueType` | Fn-value type struct (`signature`) |
| `EnvField` | Closure env capture slot (`type_idx`, `value`) |
| `PhiIncoming` | Phi node incoming pair (`value`, `block`) |

The byte size of a fn-value record is re-exported as the constant
`fn_value_size` (16).

For access to the full Module/Builder internals:

```zig
ctx.module    // ir.Module — the IR module
ctx.builder   // ir.Builder — the low-level builder
```

---

## Design Notes

### Why heap allocation?

The Builder stores a `*Module` pointer. If the Context lived on the stack, the
Builder's pointer would only be valid while the variable is in scope. Heap
allocation gives the Context a stable address for its entire lifetime.

### Value semantics

`Value` is just an `enum(u32)` — 4 bytes, trivially copyable. There is no
ownership or lifetime concern. A `Value` is valid as long as the function that
contains the producing instruction exists.

### Parameters as values

Function parameters are not instructions. By convention, parameter N is
`Value(N)`. A function with 3 parameters has `Value(0)`, `Value(1)`, and
`Value(2)` available at the start of the entry block.

### Constants

The current IR does not have a dedicated constant representation. Values that
would typically be constants (like literal integers) are passed as raw
`Value` indices. This is a known limitation that will be addressed in a
future IR version.

### Error handling

All `build*` methods return error unions (`!Value`). In the current
implementation, errors occur only when the underlying `ArrayList` allocation
fails (e.g. out of memory). Using `try` is required.

### API status

This API reflects the post-de-OOP Tungsten model. The first-class function
surface — `fnValueType`, `buildFnValue`, `buildCallPtr` (indirect calls through
a fn value with the hidden env-first argument), and `buildEnvRecord` /
`envRecordSize` for stack-allocated capture records — is implemented and
stable. There is no vtable, interface-dispatch, or `fn_array` machinery in this
API: all calls go through `buildCall` (named functions) or `buildCallPtr` (fn
values), and structs are plain aggregates with no class preamble.
