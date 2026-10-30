# Learn Wolframite

A guided, hands-on introduction to **Wolframite**, a functional-imperative
systems language implemented in Zig.

## How to use this

The core files (`core/`) teach the language from first principles. Read them in
order. Each one builds on the last.

The project files (`projects/`) teach by doing. They range from easy to hard and
reinforce what you learned in the core sections. Work through them in order.

You will need:

- **Zig 0.17.0** (pinned in `build.zig.zon`)
- **NASM** and **zig cc** on PATH if you want to *run* compiled programs
  (`ore run` / `ore build --emit-bin`). Building and testing don't need them.

## Compile and run a Wolframite file

```sh
# Build everything (Wolframite + ore binaries)
zig build

# Run a .wfr source file
zig build ore -- run examples/hello.wfr

# Or build to an executable
zig build ore -- build --emit-bin examples/hello.wfr
./hello
```

Run `zig build test-compiler` to verify the compiler passes all its tests.

## Contents

### Core concepts (read in order)
1. `core/01_how_it_works.md` — What Wolframite is, its core model
2. `core/02_syntax.md` — Tokens, comments, program structure
3. `core/03_bindings.md` — `let`/`mut`, immutability by default, assignment
4. `core/04_functions.md` — Functions, fn types, first-class fn values
5. `core/05_structs_enums.md` — Pure-data structs and enum sum types
6. `core/06_control_flow.md` — `if`, `while`, `for`, `match`
7. `core/07_errors.md` — `Result`/`Option`, postfix `?`, value-oriented errors
8. `core/08_closures.md` — Closures, capture-by-value, env records
9. `core/09_pipeline.md` — The `|>` pipeline operator and composition prelude
10. `core/10_comptime.md` — Comptime metaprogramming and generics
11. `core/11_memory.md` — Regions, RAII, explicit allocation, no lifetimes
12. `core/12_imports.md` — Modules and imports

### Projects (easy → hard)
1. `projects/01_hello_world.md` — Print "Hello, world"
2. `projects/02_calculator.md` — A small arithmetic calculator
3. `projects/03_geometry.md` — Structs and free functions
4. `projects/04_state_machine.md` — Enums and `match`
5. `projects/05_safe_division.md` — `Result`, `?`, error propagation
6. `projects/06_generic_container.md` — Generics with `Pair`/`Option`
7. `projects/07_functional_pipeline.md` — Closures, `|>`, `compose`
8. `projects/08_comptime_generics.md` — Comptime constraints with `@hasField`
9. `projects/09_multi_module.md` — Imports and modules
10. `projects/10_bootloader.md` — **Final project:** x86 bootloader via Ferro linker *(not yet possible)*
