# Frontend API Examples

Complete examples showing how to use the Tungsten frontend API to build IR
and emit code. These examples demonstrate patterns a real frontend compiler
would use.

All examples assume:

```zig
const std = @import("std");
const tungsten = @import("Tungsten");
const api = tungsten.api;
```

---

## Example 1: Simple Return

The minimal program — a function that returns a constant.

```zig
fn buildMain(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(true, 32);

    const func = try ctx.addFunction("main", i32_ty, 0);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    // Return the SSA value at index 0 (no actual constant system yet)
    const zero = @as(api.Value, @enumFromInt(0));
    _ = try ctx.buildRet(zero);
}
```

**Output:**

```
fn @main() {
  bb0:
    ret %0
}
```

---

## Example 2: Addition Function

A function that adds two parameters.

```zig
fn buildAdd(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(true, 32);

    const func = try ctx.addFunction("add", i32_ty, 2);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);
    const sum = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildRet(sum);
}
```

**Output:**

```
fn @add() {
  bb0:
    %2 = add %0, %1
    ret %2
}
```

---

## Example 3: Fibonacci (Control Flow)

Recursive fibonacci with conditional branching.

```zig
fn buildFib(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(true, 32);

    // fn fib(i32) -> i32
    const fib = try ctx.addFunction("fib", i32_ty, 1);
    ctx.setCurrentFunction(fib);

    // entry:
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const n = ctx.getParam(0);
    const zero = @as(api.Value, @enumFromInt(0));
    const cond = try ctx.buildIcmp(.icmp_sle, i32_ty, n, zero);

    const base = try ctx.appendBlock();
    const recurse = try ctx.appendBlock();
    _ = try ctx.buildCondBr(cond, base, recurse);

    // base: ret n
    ctx.setCurrentBlock(base);
    _ = try ctx.buildRet(n);

    // recurse: ret n (simplified — real fib would recurse)
    ctx.setCurrentBlock(recurse);
    _ = try ctx.buildRet(n);
}
```

**Output:**

```
fn @fib() {
  bb0:
    %0 = icmp sle %0, %1
    cond_br %0, bb1, bb2

  bb1:
    ret %0

  bb2:
    ret %0
}
```

---

## Example 4: Arithmetic Pipeline

A function chaining multiple arithmetic operations.

```zig
fn buildCompute(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(true, 32);

    const func = try ctx.addFunction("compute", i32_ty, 2);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);

    // sum = a + b
    const sum = try ctx.buildAdd(i32_ty, a, b);
    // product = sum * a
    const product = try ctx.buildMul(i32_ty, sum, a);
    // diff = product - b
    const diff = try ctx.buildSub(i32_ty, product, b);
    // quotient = diff / a
    const quotient = try ctx.buildSDiv(i32_ty, diff, a);

    _ = try ctx.buildRet(quotient);
}
```

**Output:**

```
fn @compute() {
  bb0:
    %2 = add %0, %1
    %3 = mul %2, %0
    %4 = sub %3, %1
    %5 = sdiv %4, %0
    ret %5
}
```

---

## Example 5: Bitwise Operations

```zig
fn buildBitwise(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(false, 32);

    const func = try ctx.addFunction("bitwise", i32_ty, 2);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const x = ctx.getParam(0);
    const y = ctx.getParam(1);

    const and_val = try ctx.buildAnd(i32_ty, x, y);
    const or_val = try ctx.buildOr(i32_ty, x, y);
    const xor_val = try ctx.buildXor(i32_ty, and_val, or_val);

    _ = try ctx.buildRet(xor_val);
}
```

---

## Example 6: Stack Allocation and Memory

```zig
fn buildSwap(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(true, 32);
    const ptr_ty = try ctx.ptrType(i32_ty);
    const void_ty = try ctx.voidType();

    const func = try ctx.addFunction("swap", void_ty, 2);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);

    // Load values through pointers
    const val_a = try ctx.buildLoad(i32_ty, a);
    const val_b = try ctx.buildLoad(i32_ty, b);

    // Swap
    _ = try ctx.buildStore(i32_ty, a, val_b);
    _ = try ctx.buildStore(i32_ty, b, val_a);

    _ = try ctx.buildRet(@as(api.Value, @enumFromInt(0)));
}
```

---

## Example 7: Function Calls

Two functions where one calls the other.

```zig
fn buildCallExample(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(true, 32);

    // Define callee: int helper(int x)
    const helper = try ctx.addFunction("helper", i32_ty, 1);
    ctx.setCurrentFunction(helper);

    const h_entry = try ctx.appendBlock();
    ctx.setCurrentBlock(h_entry);

    const x = ctx.getParam(0);
    _ = try ctx.buildRet(x);

    // Define caller: int caller()
    const caller = try ctx.addFunction("caller", i32_ty, 0);
    ctx.setCurrentFunction(caller);

    const c_entry = try ctx.appendBlock();
    ctx.setCurrentBlock(c_entry);

    const one = @as(api.Value, @enumFromInt(1));
    const result = try ctx.buildCall(helper, i32_ty, &.{one});
    _ = try ctx.buildRet(result);
}
```

**Output:**

```
fn @helper() {
  bb0:
    ret %0
}

fn @caller() {
  bb0:
    %1 = call @helper(%0)
    ret %1
}
```

---

## Example 8: Phi Nodes (SSA Join)

A `max` function that returns the larger of two values.

```zig
fn buildMax(ctx: *api.Context) !void {
    const i32_ty = try ctx.intType(true, 32);

    const func = try ctx.addFunction("max", i32_ty, 2);
    ctx.setCurrentFunction(func);

    // entry:
    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);

    const cond = try ctx.buildIcmp(.icmp_sgt, i32_ty, a, b);
    const bb_true = try ctx.appendBlock();
    const bb_false = try ctx.appendBlock();
    _ = try ctx.buildCondBr(cond, bb_true, bb_false);

    // bb_true: a > b
    ctx.setCurrentBlock(bb_true);
    _ = try ctx.buildBr(bb_false);

    // bb_false: join point
    ctx.setCurrentBlock(bb_false);
    const result = try ctx.buildPhi(i32_ty, &.{
        .{ .value = a, .block = bb_true },
        .{ .value = b, .block = entry },
    });
    _ = try ctx.buildRet(result);
}
```

---

## Example 9: Emitting a Relocatable Object

Building a function and emitting an ELF64 relocatable object.

```zig
fn emitAdd() !void {
    const ctx = try api.Context.init(std.heap.page_allocator, .linux_x86_64);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);

    const func = try ctx.addFunction("add", i32_ty, 2);
    ctx.setCurrentFunction(func);

    const entry = try ctx.appendBlock();
    ctx.setCurrentBlock(entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);
    const sum = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildRet(sum);

    // Emit x86-64 machine code and package it as an ELF64 object.
    const obj_bytes = try ctx.emitObject();
    defer ctx.gpa.free(obj_bytes);
}
```

---

## Example 10: Frontend Driver Pattern

A complete frontend pattern that builds multiple functions and emits code.

```zig
const std = @import("std");
const tungsten = @import("Tungsten");
const api = tungsten.api;

pub fn main() !void {
    const ctx = try api.Context.init(std.heap.page_allocator, .linux_x86_64);
    defer ctx.deinit();

    const i32_ty = try ctx.intType(true, 32);

    // ---- Build @add ----
    const add_fn = try ctx.addFunction("add", i32_ty, 2);
    ctx.setCurrentFunction(add_fn);

    const add_entry = try ctx.appendBlock();
    ctx.setCurrentBlock(add_entry);

    const a = ctx.getParam(0);
    const b = ctx.getParam(1);
    const sum = try ctx.buildAdd(i32_ty, a, b);
    _ = try ctx.buildRet(sum);

    // ---- Build @main ----
    const main_fn = try ctx.addFunction("main", i32_ty, 0);
    ctx.setCurrentFunction(main_fn);

    const main_entry = try ctx.appendBlock();
    ctx.setCurrentBlock(main_entry);

    // Call @add(1, 2) — using raw values as "constants"
    const one = @as(api.Value, @enumFromInt(1));
    const two = @as(api.Value, @enumFromInt(2));
    const result = try ctx.buildCall(add_fn, i32_ty, &.{ one, two });
    _ = try ctx.buildRet(result);

    // ---- Output ----
    // Textual IR
    std.debug.print("--- Textual IR ---\n", .{});
    try ctx.print(std.io.getStdOut().writer());

    // ELF64 relocatable object
    const obj_bytes = try ctx.emitObject();
    defer ctx.gpa.free(obj_bytes);
    std.debug.print("\n--- ELF64 object: {d} bytes ---\n", .{obj_bytes.len});
}
```

---

## Comparison: Builder API vs Frontend API

### Builder API (low-level)

```zig
var module = ir.Module.empty;
defer module.deinit(allocator);

var builder = ir.Builder.init(allocator, &module);

const i32_type = try builder.addIntType(true, 32);
_ = try builder.addVoidType();

const func = try builder.addFunction("add", i32_type, 2);
builder.setCurrentFunction(func);

const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);

const a = @as(ir.Value, @enumFromInt(0));
const b = @as(ir.Value, @enumFromInt(1));
const sum = try builder.buildAdd(i32_type, a, b);
_ = try builder.buildRet(sum);

var cg = codegen.CodeGen.init(allocator, &module);
defer cg.deinit();
const input = try cg.emitObjectModule();

var object_writer = obj_elf.Writer.init(allocator);
defer object_writer.deinit();
const obj_bytes = try object_writer.writeObject(input);
defer allocator.free(obj_bytes);

try ir.printModule(&module, std.io.getStdOut().writer());
```

### Frontend API (recommended)

```zig
const ctx = try api.Context.init(allocator, .linux_x86_64);
defer ctx.deinit();

const i32_ty = try ctx.intType(true, 32);

const func = try ctx.addFunction("add", i32_ty, 2);
ctx.setCurrentFunction(func);

const entry = try ctx.appendBlock();
ctx.setCurrentBlock(entry);

const a = ctx.getParam(0);
const b = ctx.getParam(1);
const sum = try ctx.buildAdd(i32_ty, a, b);
_ = try ctx.buildRet(sum);

try ctx.print(std.io.getStdOut().writer());

const obj_bytes = try ctx.emitObject();
defer ctx.gpa.free(obj_bytes);
```

**Key differences:**
- Single `Context` object vs separate `Module` + `Builder` + `CodeGen` + object writer
- `ctx.getParam(0)` vs `@as(ir.Value, @enumFromInt(0))`
- `ctx.emitObject()` vs manual `CodeGen` and `obj_elf.Writer` setup
- No need to import `ir.zig`, `codegen.zig`, or `obj_elf.zig` directly
