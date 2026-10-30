# ADR: ELF64 (Linux) and PE/COFF (Windows) object formats for Tungsten

## Status

Accepted

## Date

29-10-2026

## Context

Tungsten currently emits NASM x86-64 assembly text, and `ore` shells out to
`nasm` (assemble) then `zig cc` (link) to produce an executable. Tungsten will
emit an object file (ELF64 on Linux, PE/COFF on Windows) from its IR, and a new
internal linker named **Ferro** will consume those objects to produce a runnable
executable.

This ADR freezes the object file format decision so that object-emission work
and Ferro reader/linker work agree on what the object must contain before
either is implemented.

## Scope

- Target architecture: x86_64 only.
- Object kinds: relocatable object files (`ET_REL` ELF / COFF object), not
  final executables (Ferro produces the executable).
- Platforms: Linux (ELF64) and Windows (PE/COFF). macOS/Mach-O is out of
  scope.

## Decision

Tungsten emits a **relocatable object file** whose format matches the target
platform:

| Platform | Object format | File extension | Entry / global naming |
|----------|---------------|----------------|-----------------------|
| Linux    | ELF64         | `.o`           | `_main`, `__gN`, `_fnN` |
| Windows  | PE/COFF       | `.obj`         | `_main`, `__gN`, `_fnN` |

All symbols use a leading underscore (`_`) prefix, matching the existing
NASM output (`_{func}`, `__g{d}`) so the object emission path is a
byte-for-byte replacement of the assembly text rather than a new symbol
scheme.

### Relocation types

| Kind | Linux (ELF64) | Windows (PE/COFF) | Semantics | Used for |
|------|---------------|-------------------|-----------|----------|
| Absolute 64-bit address | `R_X86_64_64` (1) | `IMAGE_REL_AMD64_ADDR64` (1) | `S + A` | global data addresses (`__gN`, `_fnN`), `lea` targets outside ±2GB |
| PC-relative 32-bit | `R_X86_64_PC32` (2) | `IMAGE_REL_AMD64_REL32` (4) | `S + A - P` (sign-extended to 64) | direct `call rel32` to externs/locals, `lea [rip + disp32]`, `jmp rel32` |

`S` = symbol value, `A` = addend already present at the relocation site, `P`
= place (address of the storage unit being relocated).

For ELF64 we use **RELA** relocations (explicit addend) rather than REL,
since codegen already knows the addend (the immediate/displacement bytes
emitted at the call site). For PE/COFF the addend is implicit at the site.

### Section layout

Each object contains these sections, in this order:

| Section | Type / Characteristics | Contents | Flags |
|---------|------------------------|----------|-------|
| `.text` | `SHT_PROGBITS` / `IMAGE_SCN_CNT_EXEC_CODE` + `MEM_EXECUTE|MEM_READ` | function machine code | alloc, exec-instr/read |
| `.data` | `SHT_PROGBITS` / `IMAGE_SCN_CNT_INITIALIZED_DATA` + `MEM_READ|MEM_WRITE` | initialized globals, string literals, fn arrays | alloc, write |
| `.bss` | `SHT_NOBITS` / `IMAGE_SCN_CNT_UNINITIALIZED_DATA` + `MEM_READ|MEM_WRITE` | zero-initialized uninitialized data (no file space) | alloc, write |
| `.symtab` | `SHT_SYMTAB` / COFF symbol table | defined + undefined symbols | — |
| `.strtab` | `SHT_STRTAB` / COFF string table | symbol names | — |
| `.rel*.*` | `SHT_RELA` / per-section COFF relocation table | relocation records for `.text`, `.data` | — |

`.bss` occupies no file bytes; its size is recorded in the section header and
zero-initialized by the loader/linker.

### Symbol table semantics

- Defined symbols (functions, globals) bind `GLOBAL` / `IMAGE_SYM_CLASS_EXTERNAL`
  with their section index and value (offset within section).
- Undefined symbols (extern calls like `wfr_std_alloc`, `wfr_std_print`)
  bind `GLOBAL` with `SHN_UNDEF` / section number 0 and value 0.
- Local symbols (not needed for the initial object emission) bind `LOCAL` /
  `IMAGE_SYM_CLASS_STATIC`.
- Each symbol carries its name (offset into `.strtab`), binding, type,
  section index, value, and size.

## Alternatives considered

1. **Emit a single canonical format (e.g. ELF64 everywhere) and convert at
   link time.** Rejected: Ferro would need a cross-platform object writer
   just to consume Tungsten's output, and Windows tooling expects PE/COFF
   objects natively. Matching the platform format keeps Ferro's reader simple
   (one reader per platform, or one reader that branches on format).
2. **Keep NASM assembly and have Ferro invoke an assembler.** Rejected: this
   defeats the purpose of removing the external `nasm` dependency and makes
   object emission dependent on an external tool's text parsing quirks.
3. **Use ELF REL (no addend) instead of RELA.** Rejected: codegen knows the
   addend at emission time; RELA avoids Ferro having to re-derive addends by
   re-parsing instruction encodings.

## Consequences

### Positive

- Object emission is deterministic and self-contained: no `nasm` invocation,
  no assembly-text parsing, no dependency on NASM being on PATH.
- Format is fixed before code is written, so object-emission writers and
  Ferro reader/linker writers share one contract.
- Relocation set is minimal (PC32/REL32 + ADDR64), covering exactly the
  references codegen already emits: direct calls, global addresses, and
  fn-value/closure references.

### Negative

- Two code paths to maintain (ELF64 writer + PE/COFF writer) instead of one
  NASM emitter. Mitigated by sharing the relocation/type tables and section
  layout concepts between them.
- Object emission must now encode raw machine-code bytes instead of NASM text
  (reusing `codegen.zig` encoding logic targeting a byte buffer).

### Open questions (none — design frozen)

None. The format table, relocation types, and section layout above are final
for this ADR. Subsequent work implements against this contract; deviations
require a new ADR.

## Related

- `libs/backend/src/codegen.zig` — existing NASM emission (`section .text`,
  `section .data`, `extern` handling, `__gN` / `_{func}` naming)
