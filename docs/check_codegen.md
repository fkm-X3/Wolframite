# `ore check-codegen` — static byte-level verifier for Tungsten object files

## Overview

`ore check-codegen <file>` statically verifies a Tungsten-emitted relocatable
object file (`.o` on Linux, `.obj` on Windows) for byte-level codegen encoding
bugs **before** linking. It parses the object, disassembles each `.text`
function, and validates the encoding rules `codegen.zig` must obey.

This is **Tool 3**. It catches errors such as
truncated stack-adjustment immediates (sign-extending negative for frame sizes
> 127), missing ModR/M bytes, wrong SIB index with `rsp`/`rbp` bases, and
inconsistent REX prefixes — all without invoking the linker or executing native
code.

## Usage

```
ore check-codegen <file.o>
ore check-codegen <file.obj>
```

The object file may be produced by `ore build --obj <file.wfr>`. Both ELF64
(Linux) and PE/COFF (Windows) object formats are supported and auto-detected
from the file's magic bytes via the existing `ferro_reader` object reader.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | No violations found |
| 1 | One or more violations found |
| 2 | Usage error (missing/unexpected arguments) |

Example (clean object):
```
$ ore check-codegen examples/hello.obj
check-codegen: examples/hello.obj: no violations
```

Example (violation found):
```
$ ore check-codegen broken.obj
check-codegen: broken.obj: 1 violation(s)
  broken.obj:0: sub rsp uses 8-bit immediate for frame size > 127 (sign-extends negative) (bytes: 48 83 ec c8)
```

## What it checks

For every instruction in each `.text` function, the verifier checks:

1. **Stack-adjustment immediate width** — `sub rsp, imm8` / `add rsp, imm8`
   (opcode `0x83`, ModR/M reg field = 5/0, rm = rsp) must not use an 8-bit
   immediate whose high bit is set. Such an immediate sign-extends negative,
   turning a subtraction into an addition and corrupting the frame.

2. **SIB index** — When a SIB byte is present and its base field is `rsp`
   (`0b100`) or `rbp` (`0b101`), the index field must be "none" (`0b100`).
   Any other index with an `rsp`/`rbp` base forms an address like
   `[rsp + rax + disp]` with an uninitialized index register.

3. **REX prefix consistency** — `mov rax, imm64` (`0x48 0xB8 imm64`) must use
   REX prefix `0x48` (REX.W=1, REX.R/X/B=0). Any deviation indicates a
   misencoded constant materialization.

4. **Branch target containment** — Direct relative branches (`jmp rel32`,
   `je rel8`) and calls (`call rel32`) must resolve to an address within the
   enclosing function's `[offset, offset + size)` range.

5. **Undecodable bytes** — Trailing bytes at the end of a function that the
   decoder cannot interpret are reported (avoids cascading false positives).

## What it does NOT check

The verifier operates on raw object bytes and the symbol table; it does not:

- Resolve relocation targets to defined symbols (relocation sites are
  recorded but not cross-checked against symbol names — future work).
- Validate branch targets land at exact instruction boundaries (only that they
  lie within the enclosing function).
- Check `.data` section contents or global initializers.
- Verify phi-slot or SSA liveness (that's Tool 6, `verify_ir.zig`, not yet
  implemented).

## Implementation

- `libs/backend/src/check_codegen.zig` — `Tungsten.check_codegen` module:
  `checkObject(gpa, obj) !Report`, the x86-64 decoder (`decodeInstruction`),
  and the validation rules (`validateInstruction`).
- `src/ore/main.zig` — `ore check-codegen` CLI front-end (`cmdCheckCodegen`).
- Wired into `libs/backend/src/root.zig` (exported + test module import).

## Tests

Four unit tests live in `check_codegen.zig` and run under `zig build
test-backend`:

1. Well-formed object → zero violations.
2. `sub rsp` with a truncated 8-bit immediate → flagged with the exact message.
3. SIB index != none with `rsp` base → flagged.
4. SIB index == none with `rsp` base → accepted (no false positive).

## Related tools

`ore check-codegen` is the second-highest-leverage debug tool after the IR simulator (`sim.zig`), and it complements:

- `ore disasm` (Tool 1) — Tungsten-aware disassembler (not yet implemented).
- `ore trace` (Tool 2) — execution tracer (not yet implemented).
- IR simulator / `sim.zig` (Tool 4) — executes Tungsten IR directly (implemented).
- `ore emit-annotated` (Tool 5), slot/phi verifier (Tool 6), Ferro
  `--dump-image` (Tool 7) — not yet implemented.
