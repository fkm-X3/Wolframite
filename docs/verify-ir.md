# `verify_ir` — slot/phi liveness checker on Tungsten IR

## Overview

`verify_ir.zig` statically verifies Tungsten IR, per function:

1. **Defined-before-use** — every value slot read as an operand is defined in
   the current block or in an earlier block index (parameters are defined in
   block 0 at function entry; instruction results are defined by their own
   instruction).
2. **Single-definition without phi** — no slot is defined in more than one
   block unless a phi merges the definitions at the use site.
3. **Phi predecessor check** — every phi incoming block is a valid source for
   the value it consumes (a phi operand's `(value, block)` pair must list the
   defining block of that value).

This is **Tool 6**. It operates on Tungsten IR (not assembly), reusing
`ir.zig`'s `Module`/`Function`/`Block`/`Instruction`/`Value` structures.
Reports are collected and returned to the caller for printing — it does not
print directly.

## Module

`libs/backend/src/verify_ir.zig`, re-exported as `Tungsten.verify_ir` from
`libs/backend/src/root.zig`.

## API

```zig
pub const Report = struct {
    function: []const u8,   // name of the function containing the violation
    message: []const u8,    // human-readable description
    inst: u32,              // instruction index where detected
    operand: u32,           // operand offset within the instruction
};

pub const Verifier = struct {
    gpa: Allocator,
    module: *const ir.Module,
    reports: std.ArrayList(Report),
};

pub fn init(gpa: Allocator, module: *const ir.Module) Verifier
pub fn deinit(self: *Verifier) void
pub fn verifyAll(self: *Verifier) !u32   // returns report count
```

- `init` builds no state beyond the module reference; per-function analysis
  allocates a temporary `defined_block` array.
- `verifyAll` walks every function in the module and records violations into
  `verifier.reports`. Returns the number of reports.
- Each `Report` carries the function name, a message, the instruction index,
  and the operand offset.

## Errors detected

| Report kind | Message | Meaning |
|-------------|---------|---------|
| Undefined slot | `use of undefined slot %{d} at %{d}.{d}` | An operand slot was never defined in any block up to the use site. |
| Slot used without phi | `slot %{d} defined in block %{d} used at %{d}.{d} without phi` | A slot defined in another block is read here, and no phi incoming pair lists that defining block for that slot. |

`verifyAll` also maintains a `VerifyError` set (`OutOfBoundsSlot`,
`SlotUsedWithoutPhi`, `UndefinedSlot`) that is not currently raised by the
analysis path (reports are returned instead of aborting on first error).

## Limitations

The analysis is intentionally conservative and simple:

- It does not compute a full dominator tree. It requires a slot's defining
  block to be the current block or an earlier block index. This can flag
  forward references that are legal under a dominance criterion as violations.
- It does not verify phi incoming blocks are *predecessors* in the control-flow
  graph beyond checking the `(value, block)` pair matches a defining block;
  predecessor validity is implied by the block-index ordering but not
  explicitly recomputed from the CFG edges.

## Tests

Three tests live in `verify_ir.zig` and run under `zig build test-backend`:

1. Clean function reports zero violations.
2. `ret` reading an undefined slot is flagged (`use of undefined slot`).
3. A phi whose incoming block is not a predecessor is flagged (`without phi`).

## CLI integration

`verify_ir` is a library module (`Tungsten.verify_ir`) and has no dedicated
`ore` subcommand yet. It is designed to be invoked from `test-compiler` /
`test-backend` via the `api.Context` when a debug flag is set.

## Related tools

`verify_ir` complements:

- `ore check-codegen` — static byte-level verifier for object files.
- `ore disasm` — Tungsten-aware disassembler.
- Ferro `--dump-image` — merged image inspector.
- `ore build --emit-annotated` — IR-to-assembly annotated dump.
- IR simulator (`sim.zig`) — executes Tungsten IR directly.
