# Wolframite

[![CI](https://github.com/fkm-X3/Wolframite/actions/workflows/ci.yml/badge.svg)](https://github.com/fkm-X3/Wolframite/actions/workflows/ci.yml)

Wolframite is a **functional-imperative** systems language. It is deliberately
not object-oriented: there are no classes, interfaces, `impl` blocks, `self`, or
vtables. Code is organized around pure-data `struct`s, free functions, `enum`
sum types with `match`, and first-class closures/function values that
monomorphize to stack-allocated capture records or direct calls.

Key features:

- Immutable by default (`let`/`mut`), explicit ownership via `move`
- Comptime generics with monomorphization — no runtime type information
- Zero-cost closures plus the `compose`/`curry`/`id`/`pipe` prelude and the
  `|>` pipeline operator
- Value-oriented error handling: `Result`/`Option` with postfix `?`
- Deterministic RAII/region memory management, no garbage collector

## Quick Install

### Linux
```sh
curl -sSL https://fkm.is-a.dev/Wolframite/dev-install.sh | sh
```

### Windows
```ps1
irm https://fkm.is-a.dev/Wolframite/dev-install.ps1 | iex
```

## When 0.1.0?
Check versions/0.1.0.md

## Building from source

Requires Zig **0.17.1** to compiling from source. Building, running, and testing don't need it.

```sh
zig build                    # build everything into zig-out/ (default step)
zig build run                # build and run the app
zig build ore -- <args>      # run the ore CLI
zig build ore -- smelt       # run a smeltfile task
zig build test               # run all tests
zig build test-compiler      # run compiler-only tests (fast)
zig build test-std           # run Wolframite runtime tests
zig build install-compiler   # install Wolframite + ore to the system bin dir
```

Builds and test runs print progress and a success line (e.g. `[wolframite] all tests passed (286 tests passed)`), so if no error is shown, everything passed.

### Cross-compiling

`ore build --target <triple>` cross-compiles any Wolframite source file to a relocatable object for a target triple — no linker, no runtime, no config. The canonical triples are `x86_64-microsoft-windows` and `x86_64-unknown-linux` (no libc, hence no ABI suffix). Pass `--emit-bin` to also link an executable via Ferro:

```sh
zig build ore -- build --target x86_64-microsoft-windows src/main.wfr           # → src/main.obj (PE/COFF)
zig build ore -- build --target x86_64-unknown-linux src/main.wfr               # → src/main.o   (ELF64)
zig build ore -- build --target x86_64-microsoft-windows --emit-bin src/main.wfr  # → wfr-bin/main.exe
```

Supported targets are x86-64 Linux and Windows (bare `linux` / `windows` also work). See `docs/cross-compilation.md` for the full triple grammar and the per-target runtime archives used when linking.

### `zig build install-compiler`

Compiles `Wolframite` and `ore` and installs them into the system bin directory:

- **Windows**: `%USERPROFILE%\wolframite` (`%HOME%\wolframite` if `HOME` is set)
- **Linux**: `/usr/local/bin`, falling back to `$HOME/.local/bin` if that location is not writable (e.g. unprivileged user)

### Embedding the git SHA

`ore update --check` uses the commit SHA baked in at build time to detect newer dev builds:

```sh
zig build -Dgit-sha=$(git rev-parse HEAD)
```
