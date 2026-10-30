# ADR: Ferro linker — name, interface, and target handling

## Status

Accepted

## Date

30-10-2026

## Context

Tungsten now emits relocatable object files (ELF64 on Linux, PE/COFF on
Windows, see `adr_object_format.md`) instead of NASM assembly. A linker is
needed to turn those objects into a runnable executable, consuming the
program object plus the Wolframite runtime archive (`wfr_std`).

This ADR freezes the linker's name and its interface, so implementation work
shares one contract.

## Scope

- Linker name: **Ferro** (short for Ferrotungsten: the linker Ferro added to
  Tungsten).
- Architecture: x86_64 only. Platforms: Linux and Windows.
- Entry point contract: Tungsten names the program entry `_main`; Ferro
  synthesizes the platform entry that calls `_main` (no external shim
  assembly).
- Runtime: `wfr_std` is linked in as an object/archive Ferro reads directly;
  its lookup strategy is decided separately.
- macOS/Mach-O and other targets are out of scope.

## Decision

### Name

The internal linker is **Ferro**. The only front-facing part of the linker is
a Wolframite-link-description compiled by the normal Wolframite compiler and
handed to Ferro as structured arguments. There is no GNU linker script and
no external `ld`.

### Interface

The entry point Wolframite (ore, and any Wolframite code driving the linker
directly) talks to is:

```zig
pub fn linkObject(
    io: std.Io,
    gpa: std.mem.Allocator,
    object_path: []const u8,
    runtime_lib: []const u8,
    exe_path: []const u8,
    options: LinkOptions,
) !void
```

- `object_path` — Tungsten-emitted relocatable object for `options.target`.
- `runtime_lib` — the `wfr_std` archive/object Ferro links against.
- `exe_path` — where the final executable is written (`.exe` on Windows, no
  extension on Linux).
- `options` — `LinkOptions`: `target`, `entry_symbol` (default `_main`),
  `subsystem` (Windows console/GUI), `debug`.
- `io` / `gpa` — caller-supplied, per the "Explicit Allocation Control"
  principle. Ferro owns no global allocator.

Errors are reported as `LinkError`: `ObjectMissing`, `ObjectReadFailed`,
`RuntimeLibMissing`, `UndefinedSymbol`, `RelocationFailed`, `WriteFailed`.
Undefined-symbol and relocation errors carry enough context to surface through
the Wolframite compiler as ordinary errors — no `ld` script parsing.

### Link stages

1. `readObject(object_path)` + `readObject(runtime_lib)` — ELF64 and PE/COFF
   object reader: sections, symbol table, relocation table, string table.
2. `resolveSymbols(...)` — collect defined/undefined symbols, resolve
   undefined references against the runtime, report `UndefinedSymbol` by name.
3. `applyRelocations(...)` — apply PC32/REL32 and ADDR64 relocations, merge
   `.text`/`.data`/`.bss` from program object + runtime.
4. Entry-point wiring — synthesize the platform entry (`_start` → `_main` on
   Linux; CRT entry → `_main` on Windows) internally.
5. `writeExecutable(...)` — write ELF executable (Linux) or PE executable
   (Windows).

### Target-triple handling

The compiler (ore's compile pipeline) decides the target — from
`builtin.target` or a CLI flag — and passes it explicitly to Ferro via
`LinkOptions.target`. Ferro never derives the platform from the host OS:
`defaultLinkOptions(target)` requires the caller to supply `target`.

`Target.objectFormat(target)` maps the target to the object format Tungsten
must emit (`linux_x86_64 → elf64`, `windows_x86_64 → pe_coff`), so emission
and link agree on format without a separate config.

### Symbol naming

All symbols carry a leading underscore (`_`), matching the existing NASM
output and the object-format ADR: `_main`, `__gN`, `_fnN`. Ferro resolves
these across the program object and `wfr_std` with no external symbol
underscoring conventions.

## Alternatives considered

1. **Let Ferro guess the target from the host OS.** Rejected: violates
   "Determinism over Magic"; cross-compilation (e.g. building Windows targets
   on Linux) would silently link the wrong format.
2. **Expose the linker as a GNU ld script parsed by Tungsten.** Rejected:
   violates "Ergonomics over Purity"; link semantics must be expressed in Zig
   code the compiler controls, authored in Wolframite.
3. **Keep `nasm` + `zig cc` and have Ferro invoke them.** Rejected: defeats
   the purpose of removing external tool dependencies.

## Consequences

### Positive

- One interface (`linkObject`) frozen before implementation, so object
  emission and Ferro work agree on format, symbols, and relocations.
- Link errors (`UndefinedSymbol`, `RelocationFailed`) surface through the
  Wolframite compiler with symbol names, no `ld` cryptic output.
- No external `nasm`, `ld`, or `zig cc` dependency for the build/run path.

### Negative

- Two object formats to support (ELF64 + PE/COFF); mitigated by shared
  relocation/type tables and section-layout concepts.
- Ferro's reader/writer must be implemented for both formats before `ore` can
  cut over; until then `nasm` + `zig cc` remains the fallback.

## Related

- `libs/backend/docs/adr/adr_object_format.md` — ELF64 / PE/COFF object format,
  relocation types, section layout, symbol naming.
- `libs/backend/src/ferro.zig` — `linkObject`, `LinkOptions`, `Target`,
  `LinkError`, and stubs.
