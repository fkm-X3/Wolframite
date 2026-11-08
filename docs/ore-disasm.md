# `ore disasm` — Tungsten-aware disassembler

`ore disasm <file>` disassembles a Wolframite object file (`.o` on Linux,
`.obj` on Windows) or executable produced by the Tungsten backend. Unlike
generic tools such as `objdump`, it understands the Tungsten object model and
annotates each instruction with function symbols, byte offsets, raw bytes, and
relocation sites.

It is invocable as `zig build ore -- disasm <file>` or, once installed, as
`ore disasm <file>`.

## Usage

```
ore disasm <file.o>
ore disasm <file.obj>
```

The object format (ELF64 or PE/COFF) is detected automatically from the file's
magic bytes via the existing `ferro_reader` object reader, so the caller never
has to state it explicitly.

## Output

For each function defined in the `.text` section, `ore disasm` prints a header
line with the function symbol name and byte size, followed by one line per
instruction:

```
_main (+173 bytes):
  0 55  55
  1 4889e5  48 89 e5
  4 4883ec68  48 83 ec imm1=68
  8 488d85f0ffffff  48 8d 85 disp4=-16   ; PC32 str_0 +-4
  88 e800000000  e8 imm4=0   ; PC32 wfr_std_print +-4
  a9 c9  c9
  aa c3  c3
```

Each instruction line shows:

- **offset** — byte offset within `.text`.
- **bytes** — the raw instruction bytes in hex.
- **mnemonic** — the decoded opcode/modrm/sib/displacement/immediate fields as
  emitted by Tungsten (opcode bytes, register encodings, displacement and
  immediate values).
- **relocation annotation** (`; PC32 <symbol> +<addend>` or `; ADDR64 ...`) —
  printed inline when a relocation site falls within the instruction's byte
  range.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Disassembly succeeded |
| 1 | File missing, unreadable, or has no `.text` section |
| 2 | Usage error (missing or unexpected arguments) |

## What it does

- Parses the object file's sections, symbol table, and relocation table
  (ELF64 or PE/COFF, auto-detected).
- Disassembles each `.text` function using the x86-64 decoder shared with
  `ore check-codegen` (covering the instruction subset Tungsten emits:
  mov, lea, add, sub, cmp, setcc, jmp, je, call, push, pop, leave, ret,
  idiv/div, movzx, cqo, and REX-prefixed variants).
- Annotates relocation sites inline with symbol name, kind (PC32/ADDR64),
  and addend.
- Stops disassembling a function at undecodable bytes rather than cascading
  false positives.

## What it does not do

- It does not resolve relocation targets to their final merged addresses (that
  requires linking via Ferro).
- It does not annotate basic-block boundaries or frame-slot layout (those
  require debug info or IR cross-referencing, not yet wired in).
- It does not disassemble `.data` or other non-executable sections.
