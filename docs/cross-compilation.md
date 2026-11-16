# Cross-Compilation with `--target`

## Overview

`ore build --target <triple>` cross-compiles any Wolframite source file to a
relocatable object for a target selected with a **target triple** — from any
host, with zero configuration. Emitting an object needs nothing but the
compiler: no linker, no runtime archive, no config file.

Linking into a runnable executable stays available through `--emit-bin`. The
Ferro linker is itself a cross-linker (it writes ELF64 or PE executables
regardless of the OS it runs on), but linking additionally needs the target's
Wolframite runtime archive — which is why object output is the default when
`--target` is given.

## Usage

```
ore build --target <triple> [file]
```

```sh
# Windows x86-64 object (PE/COFF) — built from any host
ore build --target x86_64-microsoft-windows src/main.wfr   # → src/main.obj

# Linux x86-64 object (ELF64) — built from any host
ore build --target x86_64-unknown-linux src/main.wfr       # → src/main.o

# Bare platform names still work
ore build --target windows src/main.wfr

# Cross-link an executable too (needs the target's runtime archive)
ore build --target x86_64-microsoft-windows --emit-bin src/main.wfr
# → wfr-bin/main.exe
```

With no file, the `entry` from `ore.toml` is used, as with a plain
`ore build`.

### What `--target` changes

| Invocation | Output |
|------------|--------|
| `ore build <file>` | Executable for the **host** (default, unchanged): `wfr-bin/<input>.exe` |
| `ore build --target <t> <file>` | Relocatable **object** for the target: `<input>.o` (Linux) / `<input>.obj` (Windows) |
| `ore build --target <t> --emit-bin <file>` | Executable for the **target** via Ferro: `wfr-bin/<input>.exe` |
| `ore build --target <t> --ir <file>` | Textual Tungsten IR (target-independent) |

`--target` composes with `--obj`, `--ir`, and `--emit-annotated` as expected;
the object extension follows the *target* platform, not the host. Use
`-o/--output` to choose the output path, as usual.

## Accepted targets

A target is either a bare platform name or a triple of the form
`arch[-vendor]-os[-abi]`. Matching is case-insensitive, and the OS component
is located by name (so the two-part `x86_64-linux` parses the same as the
canonical `x86_64-unknown-linux`).

Wolframite's **canonical triples** are:

| Triple | Platform | Object format |
|--------|----------|---------------|
| `x86_64-unknown-linux` | Linux x86-64 | ELF64 |
| `x86_64-microsoft-windows` | Windows x86-64 | PE/COFF |

This spelling deliberately differs from GCC/LLVM, and that is fine:

- **No ABI component** (`gnu`/`musl`/`msvc`): the Wolframite runtime is
  libc-free — it talks to the kernel directly (raw syscalls on Linux,
  kernel32 on Windows) — so there is no libc flavor to name. An ABI suffix
  carries no meaning and is ignored.
- **`microsoft` as the Windows vendor** rather than the conventional `pc`:
  the target is the Microsoft Windows platform, not a PC clone.

The parser stays tolerant of foreign spellings — `x86_64-pc-windows-msvc`,
`x86_64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`,
`x86_64-w64-mingw32`, and the shorter `x86_64-linux` / `x86_64-windows`
forms — and maps them to the same two targets. `amd64` is accepted as an
alias for the `x86_64` architecture.

Anything else is rejected with a usage error: other CPU architectures
(Tungsten emits x86_64 machine code only) and other operating systems (Ferro
and the object writers support Linux and Windows only — macOS/Darwin and the
BSDs are out of scope, see the backend ADRs). Unknown targets never fall back
to a "closest" platform; they fail loudly, per the backend's "Determinism over
Magic" principle.

## Linking for the target

When you add `--emit-bin`, the same target drives both Tungsten object
emission and the Ferro link — Ferro never derives the platform from the host
OS. Linking needs the Wolframite runtime archive built for the *target*:

| Target | Archive | Build it with |
|--------|---------|---------------|
| Windows | `wfr_std.lib` (COFF) | `zig build -Dtarget=x86_64-windows` |
| Linux | `libwfr_std.a` (ELF `ar`) | `zig build -Dtarget=x86_64-linux` |

Note the spelling: zig's build-system target flag takes no vendor component,
so these `zig build` commands use zig's shorter `arch-os` form even though
ore's `--target` canonical triples name the vendor.

Both archives can coexist in `zig-out/lib` (the names differ), so one
checkout can serve as a host and cross runtime at the same time. ore's
runtime lookup only tries archive names matching the selected target — a
cross-link either finds the target's runtime or fails with `StdLibMissing`
and a hint naming the exact `zig build -Dtarget=...` command, never a
wrong-format link.

The lookup order is unchanged: project-local `zig-out/lib`, the install
layout next to the running `ore` (`<exedir>/../lib`), and the POSIX system
path `/usr/local/wolframite/lib`.

## Target triples elsewhere

The same parser backs target selection everywhere:

- `ore build --target <triple>` — the CLI flag described here.
- Wolframite **link descriptions** (the Ferro-facing `LinkerArgs` struct):
  `.target` accepts `"linux"`, `"windows"`, or a triple such as
  `"x86_64-microsoft-windows"`.

## Limitations

- x86_64 only; Linux and Windows only. There is no Apple/macOS or other
  target support, and unknown triples are rejected rather than approximated.
- Cross-compiled executables cannot be run by `ore run` / `ore test` on the
  host — those always build and execute for the host platform.
- Object output is host-independent by construction; the only per-target
  choice is the container format (ELF64 vs PE/COFF), selected by
  `ferro.objectFormat(target)`.

## Implementation

- `libs/backend/src/ferro_types.zig` — `Triple`, `parseTriple`, and the
  triple-aware `parseTarget` (backend `test-backend` covers both).
- `src/ore/main.zig` — the `--target` flag, its validation error, the
  object-only default, and the target-aware `StdLibMissing` hint.
- `src/ore/link.zig` — `targetObjectExt`, the target-aware `findWfrStdLib`
  runtime lookup, `zigTargetName`, and the `linkBinary` target parameter.

## Related

- `libs/backend/docs/adr/adr_ferro_linker.md` — target-triple handling and
  why Ferro never guesses the platform from the host OS.
- `libs/backend/docs/adr/adr_runtime_archive.md` — runtime archive lookup.
- `libs/backend/docs/adr/adr_object_format.md` — ELF64 / PE/COFF object
  formats.
- `docs/ore-emit-annotated.md` — the object-emission-only build mode that
  `--target` reuses as its default.
