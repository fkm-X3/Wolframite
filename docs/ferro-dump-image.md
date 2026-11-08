# Ferro `--dump-image` — merged image inspector

## Overview

`Ferro.linkObject` accepts a `LinkOptions.dump` flag. When set, Ferro prints
the merged image to **stderr** before writing the executable: section sizes,
every symbol's merged address, and every relocation's site/target/displacement
before and after application. PC32 displacements that sit within 1024 bytes of
the i32 limit are flagged (`<-- near i32 limit`), since those are most likely
to be truncated or mis-encoded.

This is **Tool 7**. It is intended for investigating linker-level bugs such as
wrong symbol addresses or bad displacements in the merged `.text`/`.data`
image (for example, when a function takes `>= 3` parameters and returns an
aggregate like an enum).

## Usage

The flag is exposed through `ore` as `ore build --dump-image <file.wfr>`:

```
ore build --dump-image examples/control_flow.wfr
```

When `--dump-image` is passed, `ore` links the object as usual (writing the
executable) and additionally prints the merged image dump to stderr **before**
the executable is written.

The object file may be produced by `ore build --obj <file.wfr>`; `--dump-image`
only affects the link step and requires the Wolframite runtime archive
(`wfr_std`) to be installed so Ferro can link.

## Output format

```
== Ferro merged image dump (target: windows_x86_64) ==
entry symbol: _main -> .text+0x0 = 0x0
merged .text: 1234 bytes
merged .data: 5678 bytes
merged .bss: 0 bytes

-- Symbols (merged address) --
  _main: .text+0x0 = 0x0
  str_0: .data+0x20 = 0x20

-- program relocations --
  .text .text+0x8 -> .text (0x34) | kind=PC32 addend=-4 | before_disp=-4 after_disp=48
    before bytes: 00000000
  .data .data+0x20 -> .data (0x20) | kind=ADDR64 addend=0 | before_disp=0 after_disp=8192
    before bytes: 0000000000000000

-- runtime relocations --
  .text .text+0x100 -> .text (0x100) | kind=PC32 addend=-4 | before_disp=-4 after_disp=12
```

For each relocation line:

| Field | Meaning |
|-------|---------|
| `.text` / `.data` | Section the relocation applies to |
| `+0xN` | Offset within the section where the relocated bytes live |
| `-> .text (0x34)` | Target symbol's section and merged offset |
| `kind=PC32` / `kind=ADDR64` | Relocation kind |
| `addend=N` | Addend already present at the site |
| `before_disp` | Displacement before patching (raw addend) |
| `after_disp` | Displacement after applying `S + A - P` (PC32) / `S + A` (ADDR64) |
| `before bytes` | Raw bytes currently sitting at the site |
| `<-- near i32 limit` | PC32 displacement within 1024 bytes of the i32 min/max |

## What it does

- Dumps merged `.text`, `.data`, and `.bss` sizes.
- Lists every symbol's final merged address (section + offset + full value).
- For every relocation in both the program object and the runtime archive,
  computes and prints the site, target symbol, kind, addend, and the
  before/after displacement.
- Flags PC32 displacements near the i32 limit.

## What it does NOT do

- It does not write a separate dump file; output goes to stderr only.
- It does not validate that displacements are actually correct; it reports
  them so a developer can compare against intent.
- It does not annotate `.data` contents as text.

## Implementation

- `libs/backend/src/ferro_types.zig` — `LinkOptions.dump` field, plumbed
  through `defaultLinkOptions` and `linkOptionsFromDescription`.
- `libs/backend/src/ferro.zig` — `dumpMergedImage(io, image, program,
  runtime, options)` and the call site in `linkObject` that prints it before
  `writeExecutable`.
- `src/ore/link.zig` — `linkBinary(..., dump_image: bool)` threads the flag
  into Ferro's `LinkOptions`.
- `src/ore/main.zig` — `ore build --dump-image` option parsing and help text.
- Exported as part of `Tungsten.ferro` (`libs/backend/src/root.zig`).

## Tests

The `defaultLinkOptions` test in `ferro.zig` asserts `opts.dump == false`.
`zig build test` passes with the dump code path compiled in but inactive
unless `--dump-image` is passed.

## Related tools

Ferro `--dump-image` complements:

- `ore check-codegen` — static byte-level verifier for object files.
- `ore disasm` — Tungsten-aware disassembler.
- `ore build --emit-annotated` — IR-to-assembly annotated dump.
- `verify_ir` — slot/phi liveness checker on IR.
- IR simulator (`sim.zig`) — executes Tungsten IR directly.
