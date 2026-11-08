# `ore trace` — execution tracer

## Overview

`ore trace <file> [args...]` executes a Wolframite program previously built
with `ore build` and reports how the run ended — exit code or abnormal
termination. It wraps execution as a child process, captures the termination
status, and prints the result to stdout/stderr.

This is **Tool 2**. It is the lowest-overhead way to observe a program's
termination behavior without a full debugger.

## Usage

```
ore trace <file.wfr>
ore trace -o <path>.exe <file.wfr>
ore trace <file.wfr> <arg1> <arg2>
```

`ore trace` does **not** compile or link; the executable must already exist
(produced by `ore build`). When no file is given, the entry from `ore.toml`
is used to locate the executable (`<input>.exe`). Arguments after the file
are passed to the program.

## Output

Normal exit:
```
trace: executing 'examples\hello.exe'
Hello, world!
trace: 'examples\hello.exe' exited with code 0
```

Abnormal termination:
```
trace: executing 'examples\control_flow.exe'
trace: 'examples\control_flow.exe' terminated abnormally
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Program exited with code 0 |
| N | Program exited with non-zero code N (propagated) |
| 1 | Program terminated abnormally, or could not be started/waited on |
| 2 | Usage error |

## What it does

- Resolves the executable path from the source file (or `ore.toml` entry).
- Verifies the executable exists before attempting to run it.
- Spawns the executable as a child process with inherited stdio (so program
  output appears directly in the terminal).
- Waits for the child to terminate and reports the exit code or abnormal
  termination.

## What it does NOT do

- It does **not** inject per-function tracing hooks or record function entry
  counts. Full per-function tracing (as described in the debugger tooling
  design) requires a `-Dtrace` codegen hook plus runtime ring-buffer support,
  which is not yet implemented.
- It does **not** print register state at function entry/exit.
- It does **not** capture a ring buffer dump on crash (that requires the
  runtime tracing hook).

## Implementation

- `src/ore/main.zig` — `cmdTrace(gpa, io, args)` CLI front-end, `printTraceHelp`
  help text, and the `"trace"` command registration in `runCommand`.
- Reuses `spawnOrShell` (direct spawn with shell fallback on `InvalidExe`)
  and `resolveSource` / `replaceExt` from `link.zig`.

## Related tools

`ore trace` complements:

- `ore check-codegen` — static byte-level verifier for object files.
- `ore disasm` — Tungsten-aware disassembler.
- Ferro `--dump-image` — merged image inspector.
- `ore build --emit-annotated` — IR-to-assembly annotated dump.
- `verify_ir` — slot/phi liveness checker on IR.
- IR simulator (`sim.zig`) — executes Tungsten IR directly.
