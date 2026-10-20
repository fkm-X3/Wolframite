# Wolframite

[![CI](https://github.com/fkm-X3/Wolframite/actions/workflows/ci.yml/badge.svg)](https://github.com/fkm-X3/Wolframite/actions/workflows/ci.yml)

Wolframite, the lang built on top of Tungsten

> [!IMPORTANT]
> This project is not abandoned (I'm am balancing working on cube combat and this project) and the syntax is locked to Zig 0.16.

## Quick Install

### Linux
```sh
curl -sSL https://fkm.is-a.dev/Wolframite/install.sh | sh
```

### Windows
```ps1
irm https://fkm.is-a.dev/Wolframite/install.ps1 | iex
```

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

- **Windows**: `%USERPROFILE%\.local\bin` (`%HOME%\.local\bin` if `HOME` is set)
- **Linux**: `/usr/local/bin`, falling back to `$HOME/.local/bin` if that location is not writable (e.g. unprivileged user)

### Embedding the git SHA

`ore update --check` uses the commit SHA baked in at build time to detect newer dev builds:

```sh
zig build -Dgit-sha=$(git rev-parse HEAD)
```
