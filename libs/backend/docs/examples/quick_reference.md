# Tungsten IR Quick Reference

## Key Concepts

### 1. Handles (4 bytes)
- `Value` - SSA value reference (instruction result)
- `TypeIdx` - Type table index
- `InstructionIdx` - Instruction array index
- `BasicBlockIdx` - Basic block array index
- `FunctionIdx` - Function array index

### 2. Flat Storage
- Instructions stored in contiguous arrays
- Operands stored in separate `extra_data` array
- Cache-friendly sequential access

### 3. SSA Form
- Each instruction produces at most one value
- `Value(N)` = result of instruction at index N
- No separate "result" field needed

## Instruction Reference

### Arithmetic
| Opcode | Format | Description |
|--------|--------|-------------|
| `add` | `%r = add %a, %b` | Addition |
| `sub` | `%r = sub %a, %b` | Subtraction |
| `mul` | `%r = mul %a, %b` | Multiplication |
| `sdiv` | `%r = sdiv %a, %b` | Signed division |
| `udiv` | `%r = udiv %a, %b` | Unsigned division |

### Bitwise
| Opcode | Format | Description |
|--------|--------|-------------|
| `and` | `%r = and %a, %b` | Bitwise AND |
| `or` | `%r = or %a, %b` | Bitwise OR |
| `xor` | `%r = xor %a, %b` | Bitwise XOR |
| `shl` | `%r = shl %a, %b` | Shift left |
| `shr` | `%r = shr %a, %b` | Shift right |

### Comparison
| Opcode | Format | Description |
|--------|--------|-------------|
| `icmp eq` | `%r = icmp eq %a, %b` | Equal |
| `icmp ne` | `%r = icmp ne %a, %b` | Not equal |
| `icmp slt` | `%r = icmp slt %a, %b` | Signed less than |
| `icmp sle` | `%r = icmp sle %a, %b` | Signed less or equal |
| `icmp sgt` | `%r = icmp sgt %a, %b` | Signed greater than |
| `icmp sge` | `%r = icmp sge %a, %b` | Signed greater or equal |
| `icmp ult` | `%r = icmp ult %a, %b` | Unsigned less than |
| `icmp ule` | `%r = icmp ule %a, %b` | Unsigned less or equal |
| `icmp ugt` | `%r = icmp ugt %a, %b` | Unsigned greater than |
| `icmp uge` | `%r = icmp uge %a, %b` | Unsigned greater or equal |

### Control Flow
| Opcode | Format | Description |
|--------|--------|-------------|
| `br` | `br bb_target` | Unconditional branch |
| `cond_br` | `cond_br %c, bb_true, bb_false` | Conditional branch |
| `ret` | `ret %value` | Return |
| `trap` | `trap` | Terminate execution with a processor trap |

### Memory
| Opcode | Format | Description |
|--------|--------|-------------|
| `alloca` | `%r = alloca` | Allocate stack memory |
| `load` | `%r = load %ptr` | Load from pointer |
| `store` | `store %ptr, %value` | Store to pointer |

### SSA
| Opcode | Format | Description |
|--------|--------|-------------|
| `phi` | `%r = phi [ %v, bb ] ...` | Select value based on predecessor |
| `call` | `%r = call @fn(args...)` | Call function |

## Builder API Methods

### Type Construction
```zig
builder.addVoidType()           // -> TypeIdx
builder.addBoolType()           // -> TypeIdx
builder.addIntType(signed, bits) // -> TypeIdx
builder.addFloatType(float)     // -> TypeIdx
builder.addPointerType(elem)    // -> TypeIdx
builder.addFunctionType(ret, params) // -> TypeIdx
```

### Function Construction
```zig
builder.addFunction(name, return_type) // -> FunctionIdx
builder.setCurrentFunction(func)
```

### Basic Block Construction
```zig
builder.appendBlock()           // -> BasicBlockIdx
builder.setCurrentBlock(block)
```

### Instruction Construction
```zig
builder.buildAdd(type, lhs, rhs)    // -> Value
builder.buildSub(type, lhs, rhs)    // -> Value
builder.buildMul(type, lhs, rhs)    // -> Value
builder.buildSDiv(type, lhs, rhs)   // -> Value
builder.buildUDiv(type, lhs, rhs)   // -> Value
builder.buildAnd(type, lhs, rhs)    // -> Value
builder.buildOr(type, lhs, rhs)     // -> Value
builder.buildXor(type, lhs, rhs)    // -> Value
builder.buildShl(type, lhs, rhs)    // -> Value
builder.buildShr(type, lhs, rhs)    // -> Value
builder.buildIcmp(cond, type, lhs, rhs) // -> Value
builder.buildBr(target)             // -> Value
builder.buildCondBr(cond, t, f)     // -> Value
builder.buildRet(val)               // -> Value
builder.buildCall(func, type, args) // -> Value
builder.buildAlloca(type)           // -> Value
builder.buildLoad(type, ptr)        // -> Value
builder.buildStore(type, ptr, val)  // -> Value
builder.buildPhi(type, incoming)    // -> Value
```

## Memory Layout Summary

### Instruction (12 bytes)
```
[opcode: u8] [type_idx: u32] [operands: {start: u32, len: u16}]
```

### BasicBlock (8 bytes)
```
[first_inst: u32] [inst_count: u32]
```

### Value (4 bytes)
```
[index: u32]  // References instruction result
```

## Comparison with LLVM

| Feature | LLVM | Tungsten |
|---------|------|----------|
| Node size | 48-64 bytes | 12 bytes |
| Pointer size | 8 bytes | 4 bytes |
| Memory overhead | High (intrusive lists) | Low (flat arrays) |
| Cache locality | Poor | Excellent |
| Serialization | Complex | Trivial |
