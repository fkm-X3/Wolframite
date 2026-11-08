# Debug Tools: Tungsten IR Simulator

Documents the IR-level interpreter / simulator (`Tool 4` from `docs/debugging.md`),
implemented as `libs/backend/src/sim.zig`. It executes Tungsten IR directly
without object emission or Ferro, isolating codegen bugs from linker bugs.

## Purpose

Run Tungsten IR (`ctx.print` / `--ir` output) on a register/slot machine that
mirrors `codegen.zig`'s frame layout. Every value occupies one 8-byte slot at a
fixed offset from the frame base, exactly as the object emitter assumes. This
catches codegen bugs (wrong stack adjustments, missing ModR/M bytes, bad SIB
index, wrong REX, truncated immediates, unresolved branches, phi handling) without
linking or executing native code.

## Module

`libs/backend/src/sim.zig`, re-exported as `Tungsten.sim` from
`libs/backend/src/root.zig`.

### Core types

```zig
pub const Simulator = struct { ... };

pub const CallFrame = struct {
    func: usize,
    block: usize,
    pc: usize,
    retval_slot: usize,
};

pub const RunResult = struct {
    retval: i64,
    halted: bool,
    err: ?SimError,
};

pub const PcAction = enum { advance, set };

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
```

### API

```zig
pub fn init(gpa: Allocator, module: *const ir.Module, func_idx: usize) !Simulator
pub fn deinit(self: *Simulator) void
pub fn setTrace(self: *Simulator, w: *std.Io.Writer) void
pub fn run(self: *Simulator) !void
pub fn runFunction(gpa, module, func_idx) !RunResult
```

- `init` builds the flat block map (entry PC + instruction count per block) for
  the given function so branches can jump by block index.
- `run` executes until the current function executes `ret`/`ret_void` or traps.
  Calls to other functions are handled via an explicit call stack (`enterFrame`),
  so recursion is iterative, not via Zig call frames.
- `setTrace` enables per-instruction logging (`opcode %slot = value`) to a
  `std.Io.Writer`, useful for diffing intended vs. actual slot values.
- `runFunction` is a convenience that runs a function with no arguments and
  returns its `i64` result bits.

### Frame model

The simulator reuses `ir.zig`'s types (`Module`, `Function`, `Instruction`,
`Value`, `Opcode`, `IrType`) directly. Slot indexing:

- Params occupy slots `0..param_count`.
- Instruction results occupy `param_count + instruction_index`.
- Slots grow lazily; reads of undefined slots return `UninitializedSlot`.
- `alloca` extends the slot array and returns a pointer (slot index) into it;
  `load`/`store` dereference that pointer.
- `func_addr` writes the callee function index into a slot; `call_ptr` reads the
  `fn_ptr` word (`slot + 0`) as the callee index and ignores `env_ptr` (`slot +
  1`, opaque in the simulator). This matches the uniform hidden-env-parameter ABI
  (`docs/semantics.md` §6.2).

### Supported opcodes

All opcodes Tungsten emits:

| Group | Opcodes |
|-------|---------|
| Constants | `iconst`, `fconst` |
| Integer arithmetic | `add`, `sub`, `mul`, `sdiv`, `udiv`, `srem`, `urem` |
| Bitwise | `and_op`, `or_op`, `xor_op`, `shl`, `shr` |
| Float arithmetic | `fadd`, `fsub`, `fmul`, `fdiv` |
| Integer comparison | `icmp_eq`, `icmp_ne`, `icmp_slt`, `icmp_sle`, `icmp_sgt`, `icmp_sge`, `icmp_ult`, `icmp_ule`, `icmp_ugt`, `icmp_uge` |
| Float comparison | `fcmp_oeq`, `fcmp_one`, `fcmp_olt`, `fcmp_ole`, `fcmp_ogt`, `fcmp_oge` |
| Control flow | `br`, `cond_br`, `ret`, `ret_void` |
| Calls | `call`, `call_ptr` |
| Memory | `alloca`, `load`, `store`, `ptr_add` (`malloc` unimplemented) |
| Globals / addresses | `global_addr`, `func_addr` |
| SSA | `phi` (resolves the incoming value from the current predecessor block) |

### Errors detected

- `UninitializedSlot` — read before write (use of uninitialized slot).
- `DivideByZero` — `sdiv`/`udiv`/`srem`/`urem` by zero.
- `InvalidBranchTarget` — branch to a block index out of range, or falling off
  the end of a function without `ret`.
- `ExternalCallUnimplemented` — `extern_call` has no simulator implementation.
- `MallocUnimplemented` — `malloc` has no simulator implementation.
- `UnsupportedOpcode` — defensive; all emitted opcodes are handled.

### Example usage

```zig
const tungsten = @import("Tungsten");
const sim = tungsten.sim;
const ir = tungsten.ir;

// Build a module with the `ir`/`api` builders ...
var module = ir.Module.empty;
defer module.deinit(gpa);
var builder = ir.Builder.init(gpa, &module);
const i32_ty = try builder.addIntType(true, 32);
const func = try builder.addFunction("add", i32_ty, 2);
builder.setCurrentFunction(func);
const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);
const a = @as(ir.Value, @enumFromInt(0));
const b = @as(ir.Value, @enumFromInt(1));
const sum = try builder.buildAdd(i32_ty, a, b);
_ = try builder.buildRet(sum);

// Run it.
var s = try sim.Simulator.init(gpa, &module, @intFromEnum(func));
defer s.deinit();
try s.writeSlot(0, 3);
try s.writeSlot(1, 7);
try s.run();
// s.retval == 10

// With trace:
var buf: [4096]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);
s.setTrace(&w);
try s.run();
// buf now contains "iconst %2 = 3\nadd %3 = 10\nret %2 = 10\n..." etc.
```

### Tests

Four tests live in `sim.zig` and run under `zig build test-backend`:

1. `sim executes add of two params` — `add(3, 7) == 10`.
2. `sim executes conditional branch between two blocks` — both branch targets
   (`bb1 → 42`, `bb2 → 7`) produce correct results.
3. `sim detects uninitialized slot read` — returns `UninitializedSlot`.
4. `sim executes function call` — `caller(5)` calls `callee(5) → 5`; result `6`.

### CLI integration (not yet done)

`debugger.md` proposes invoking it as `zig build run -- --sim <file.ir>` or
`ore run --sim <file>`. That requires an IR text parser (to turn `ctx.print`
output back into an `ir.Module`) and a CLI front-end, neither of which exists
yet. The simulator module is importable as `Tungsten.sim` and ready for that
front-end to be built on top of it.

## Relationship to other tools

Per `docs/debugging.md` §4 (recommended priority), the IR simulator is the
highest-leverage debug tool: it would have caught codegen bugs #1–#7 without
needing to link or run native code. It complements:

- `ore check-codegen` (Tool 3) — static byte-level verifier for object files.
- `ore disasm` (Tool 1) — Tungsten-aware disassembler.
- `verify_ir.zig` (Tool 6) — slot/phi liveness checker on IR.

None of those are implemented yet; only the simulator (`sim.zig`) exists.
