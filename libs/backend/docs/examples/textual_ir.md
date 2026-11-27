# Tungsten Textual IR Examples

Tungsten's IR uses a simple, SSA-based textual format close to standard assembly syntax.

## Basic Structure

```
fn @function_name(param_type %param) -> return_type {
  label:
    instruction
}
```

## Example 1: Simple Return

A function that returns a constant value:

```
fn @main() -> i32 {
  entry:
    ret %0
}
```

**In-memory layout:**
- `Value(0)` = the constant 42 (stored in extra_data)
- 1 basic block: `entry`
- 1 instruction: `ret`

## Example 2: Fibonacci (Recursive)

```
fn @fib(i32 %n) -> i32 {
  entry:
    %0 = icmp sle %n, 1
    cond_br %0, bb1, bb2

  bb1:
    ret %n

  bb2:
    %1 = sub %n, 1
    %2 = call @fib(%1)
    %3 = sub %n, 2
    %4 = call @fib(%3)
    %5 = add %2, %4
    ret %5
}
```

**In-memory layout:**
- 3 basic blocks: `entry`, `bb1`, `bb2`
- 8 instructions total
- `Value(0)` through `Value(7)` reference instruction results

## Example 3: Arithmetic Operations

```
fn @compute(i32 %a, i32 %b) -> i32 {
  entry:
    %0 = add %a, %b
    %1 = mul %0, %a
    %2 = sub %1, %b
    %3 = sdiv %2, %a
    ret %3
}
```

**Instruction breakdown:**
| Index | Opcode | Operands | Result |
|-------|--------|----------|--------|
| 0 | `add` | `%a`, `%b` | `%0` |
| 1 | `mul` | `%0`, `%a` | `%1` |
| 2 | `sub` | `%1`, `%b` | `%2` |
| 3 | `sdiv` | `%2`, `%a` | `%3` |

## Example 4: Bitwise Operations

```
fn @bitwise(i32 %x, i32 %y) -> i32 {
  entry:
    %0 = and %x, %y
    %1 = or %x, %y
    %2 = xor %x, %y
    %3 = shl %0, 2
    %4 = shr %1, 1
    ret %4
}
```

## Example 5: Comparisons

```
fn @compare(i32 %a, i32 %b) -> i1 {
  entry:
    %0 = icmp eq %a, %b
    %1 = icmp slt %a, %b
    %2 = icmp uge %a, %b
    %3 = and %0, %1
    ret %3
}
```

**Available comparison opcodes:**
- `icmp eq` - equal
- `icmp ne` - not equal
- `icmp slt` - signed less than
- `icmp sle` - signed less or equal
- `icmp sgt` - signed greater than
- `icmp sge` - signed greater or equal
- `icmp ult` - unsigned less than
- `icmp ule` - unsigned less or equal
- `icmp ugt` - unsigned greater than
- `icmp uge` - unsigned greater or equal

## Example 6: Control Flow (If-Else)

```
fn @max(i32 %a, i32 %b) -> i32 {
  entry:
    %0 = icmp sgt %a, %b
    cond_br %0, bb1, bb2

  bb1:
    ret %a

  bb2:
    ret %b
}
```

## Example 7: Loop with Phi Node

```
fn @sum(i32 %n) -> i32 {
  entry:
    %0 = icmp sle %n, 0
    cond_br %0, bb_exit, bb_loop

  bb_loop:
    %1 = phi [ %3, bb_entry ] [ %0, bb_loop ]
    %2 = phi [ %n, bb_entry ] [ %4, bb_loop ]
    %3 = add %1, %2
    %4 = sub %2, 1
    %5 = icmp sle %4, 0
    cond_br %5, bb_exit, bb_loop

  bb_exit:
    %6 = phi [ %0, bb_entry ] [ %3, bb_loop ]
    ret %6
}
```

**Note:** `phi` nodes select values based on which basic block was taken:
- `[ value, block ]` pairs indicate "if we came from `block`, use `value`"

## Example 8: Memory Operations

```
fn @swap(i32* %a, i32* %b) -> void {
  entry:
    %0 = load %a
    %1 = load %b
    store %a, %1
    store %b, %0
    ret void
}
```

**Memory opcodes:**
- `alloca` - allocate stack memory
- `load` - load from pointer
- `store` - store to pointer

## Example 9: Function Calls

```
fn @add(i32 %a, i32 %b) -> i32 {
  entry:
    %0 = add %a, %b
    ret %0
}

fn @main() -> i32 {
  entry:
    %0 = call @add(1, 2)
    %1 = call @add(%0, 3)
    ret %1
}
```

**Call instruction format:**
- `call @function_name(arg1, arg2, ...)`
- First operand is the function index
- Remaining operands are arguments

## Example 10: Complex Control Flow

```
fn @abs_diff(i32 %a, i32 %b) -> i32 {
  entry:
    %0 = icmp sgt %a, %b
    cond_br %0, bb_greater, bb_lesser

  bb_greater:
    %1 = sub %a, %b
    ret %1

  bb_lesser:
    %2 = sub %b, %a
    ret %2
}
```

## Summary of Instruction Formats

| Instruction | Format | Produces Value |
|-------------|--------|----------------|
| `add` | `%result = add %lhs, %rhs` | Yes |
| `sub` | `%result = sub %lhs, %rhs` | Yes |
| `mul` | `%result = mul %lhs, %rhs` | Yes |
| `sdiv` | `%result = sdiv %lhs, %rhs` | Yes |
| `udiv` | `%result = udiv %lhs, %rhs` | Yes |
| `and` | `%result = and %lhs, %rhs` | Yes |
| `or` | `%result = or %lhs, %rhs` | Yes |
| `xor` | `%result = xor %lhs, %rhs` | Yes |
| `shl` | `%result = shl %lhs, %rhs` | Yes |
| `shr` | `%result = shr %lhs, %rhs` | Yes |
| `icmp` | `%result = icmp cond %lhs, %rhs` | Yes |
| `br` | `br bb_target` | No |
| `cond_br` | `cond_br %cond, bb_true, bb_false` | No |
| `ret` | `ret %value` | No |
| `trap` | `trap` | No |
| `call` | `%result = call @fn(args...)` | Yes |
| `alloca` | `%result = alloca` | Yes |
| `load` | `%result = load %ptr` | Yes |
| `store` | `store %ptr, %value` | No |
| `phi` | `%result = phi [ %val, bb ] ...` | Yes |
