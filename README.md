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
For the 0.1.0 to release the Tungsten backend compiler will have to emit binary objects directly then it will invoke the linker Ferro (short for Ferrotungsten) which isn't front facing in the way lld or gnu ld is, its internal but can be accessed by args in the Wolframite syntax. There will also have to be good enough documentation so that someone that knows basic programming principles can pick up the language (like the rust book. I'll probably just use mdbook as its what the rust book uses).


## Building from source

Requires Zig **0.16.0**. NASM and `zig cc` must be on PATH to *run* compiled programs (`ore run` / `ore build --emit-bin` shell out to them) — building and testing don't need them.

```sh
zig build                    # build everything into zig-out/ (default step)
zig build run                # build and run the app
zig build ore -- <args>      # run the ore CLI
zig build test               # run all tests
zig build test-compiler      # run compiler-only tests (fast; this is all CI runs)
zig build test-std           # run Wolframite runtime tests
zig build install-compiler   # install Wolframite + ore to the system bin dir
```

Builds and test runs print progress and a success line (e.g. `[wolframite] all tests passed (286 tests passed)`), so if no error is shown, everything passed.

### `zig build install-compiler`

Compiles `Wolframite` and `ore` and installs them into the system bin directory:

- **Windows**: `%USERPROFILE%\wolframite` (`%HOME%\wolframite` if `HOME` is set)
- **Linux**: `/usr/local/bin`, falling back to `$HOME/.local/bin` if that location is not writable (e.g. unprivileged user)

### Embedding the git SHA

`ore update --check` uses the commit SHA baked in at build time to detect newer dev builds:

```sh
zig build -Dgit-sha=$(git rev-parse HEAD)
```
