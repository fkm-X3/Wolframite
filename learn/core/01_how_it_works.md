# 01. How Wolframite Works

Wolframite is a **functional-imperative systems language**. It gives you
fine-grained hardware control and predictable execution costs without exposing
you to explicit lifetime parameters or a borrow checker.

It is implemented in Zig and targets **Tungsten**, a Zig backend that emits
x86-64 machine code (currently via NASM assembly; a native object emitter plus
the **Ferro** internal linker is planned — see `core/11_memory.md` for the
memory side, and the final project for the linker story).

## The core ideas

Wolframite is deliberately **not object-oriented**. There are:

- No `class`, no `impl`, no `interface`, no `Self`, no hidden `this`, no
  vtables.
- No garbage collector, no tracing, no non-deterministic finalizers.
- No lifetime annotations (`'a`-style syntax does not exist).

Instead, Wolframite is built around:

| Concept | What it means |
|---|---|
| **Pure-data `struct`** | A `struct` is just a bundle of fields. Behavior lives in free functions that take the struct as a parameter. |
| **Free functions** | Functions are not attached to types. You call `add(v1, v2)` or `v1 |> add(v2)`, never `v1.add(v2)`. |
| **Immutable by default** | `let` creates an immutable binding; `mut` makes one explicitly mutable. Parameters are immutable unless `mut`. |
| **Enum sum types + `match`** | `enum` defines tagged unions. `match` pattern-matches on them exhaustively. |
| **`Result`/`Option` + `?`** | Errors are values, not exceptions. `?` unwraps or early-returns. |
| **First-class closures** | `|x| x + 1` creates a closure. Closures capture by value into stack-allocated env records. |
| **`|>` pipeline** | `v |> f` threads `v` into `f`. Composes with `compose`, `curry`, `id`, `pipe`. |
| **Comptime generics** | Generics are resolved at compile time. `comptime` blocks and `@`-builtins do metaprogramming. |
| **Region memory** | `region name { ... }` creates an arena freed at block exit. Allocation is explicit and deterministic. |

## A tiny program

```wfr
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

fn main() -> i32 {
    let x = add(2, 3)
    return x
}
```

- `fn add(...)` declares a free function.
- `let x = ...` creates an immutable binding (type inferred as `i32`).
- `main` is the program entry point; it returns `i32`.
- `return x` exits `main` with the value.

## What makes Wolframite unique

1. **No OOP.** There is no method syntax. A `struct` holds data only; free
   functions operate on it. This removes `self`, `this`, vtables, and hidden
   pointers entirely.

2. **Immutable-by-default with explicit mutability.** You must write `mut` to
   make a binding changeable. Assignment targets only `mut` bindings. This makes
   where mutation happens obvious at a glance.

3. **Zero-cost functional abstractions.** Closures, `compose`, `curry`, and the
   `|>` pipeline all monomorphize down to stack-allocated capture records or
   direct function calls — no heap, no boxing, no runtime overhead.

4. **Comptime instead of macros.** You write ordinary Wolframite code that runs
   during compilation (`comptime`), using builtins like `@typeOf`, `@sizeOf`,
   `@hasField`, `@assert`. Generics are comptime monomorphization, not runtime
   type erasure.

5. **Value-oriented errors.** `Result[T, E]` and `Option[T]` are ordinary enum
   sum types. The postfix `?` operator unwraps them, compiling down to a simple
   branch-to-return — no exception unwinding, no runtime cost beyond a branch.

6. **Deterministic regions.** Memory is freed when it leaves scope (RAII) or
   when a `region` block exits. There is no garbage collector and no borrow
   checker fighting you.

## What this tutorial assumes

You should know basic programming (variables, functions, loops, conditionals).
No systems-programming or Zig knowledge is required — we will introduce each
Wolframite concept as we go.

## Next

Read `core/02_syntax.md` to learn the tokens, comments, and structure of a
Wolframite program.
