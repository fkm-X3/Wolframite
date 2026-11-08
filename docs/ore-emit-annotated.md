# `ore build --emit-annotated` — object file emitter

## Overview

`ore build --emit-annotated <file.wfr>` compiles a Wolframite source file and
writes a relocatable object file (`.o` on Linux, `.obj` on Windows). It runs
the normal compiler pipeline (lexer → parser → resolver → typecheck → Tungsten
lowering → object emission) and produces the same object file that `ore build
--obj` produces.

This is **Tool 5** (asm output removed from the project).

## Usage

```
ore build --emit-annotated examples/hello.wfr
```

This writes:

- `examples/hello.obj` (Windows) or `examples/hello.o` (Linux) — the
  relocatable object file, identical to what `ore build --obj` produces.

`--emit-annotated` is mutually exclusive with `--emit-bin` (it does not link
into an executable). Use `--output <path>` to choose the object file path.

## What it does

- Runs the normal compiler pipeline on the source file.
- Lowers the module to Tungsten IR via the `api.Context` / `codegen` machinery.
- Emits a relocatable object file via `ByteEncoder` / `codegen.emitObject()`.
- Writes the `.o` / `.obj` file.

## What it does NOT do

- It does not link into an executable (no `--emit-bin`).
- It does not produce asm output (asm was removed from the project).

## Implementation

- `src/ore/compile.zig` — `compileAnnotated(arena, source, target)` runs the
  pipeline once and returns the relocatable object bytes.
- `src/ore/main.zig` — `ore build --emit-annotated` option parsing, object
  file writing, and help text.

## Tests

Backend unit tests in `codegen.zig` run under `zig build test-backend`. `zig
build test` passes.

## Related tools

`ore build --emit-annotated` complements:

- `ore check-codegen` — static byte-level verifier for object files.
- `ore disasm` — Tungsten-aware disassembler.
- Ferro `--dump-image` — merged image inspector.
- `verify_ir` — slot/phi liveness checker on IR.
- IR simulator (`sim.zig`) — executes Tungsten IR directly.
