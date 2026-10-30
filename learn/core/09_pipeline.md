# 09. The Pipeline Operator and Composition Prelude

Wolframite has a pipeline operator `|>` and a small composition prelude
(`id`, `pipe`, `compose`, `curry`, `uncurry`) that let you write code in a
functional, data-flow style — all of which compile down to direct calls with
zero runtime overhead.

## The `|>` pipeline operator

`lhs |> rhs` threads the left-hand value into the right-hand call:

```wfr
let a = 3 |> inc           // inc(3)
let b = 10 |> add(5)       // add(10, 5)
let c = 10 |> add(_, 3)    // add(10, 3)  (`_` is the hole)
let d = 3 |> inc |> double // double(inc(3)) == 8
```

Rules:
- `lhs |> f(x)` → `f(lhs, x)` — piped value becomes argument 0.
- `lhs |> f(_, x)` → `f(lhs, x)` — piped value fills the `_` hole.
- `lhs |> f` → `f(lhs)` — bare function name means application.
- Pipelines are left-associative: `a |> b |> c` → `c(b(a))`.
- Exactly one `_` is allowed per piped call.

This reads naturally left-to-right: "take 3, increment it, then double it."

## The composition prelude

Five functions are predeclared in every module (no `import` needed):

| Prelude | Meaning | Expansion |
|---|---|---|
| `id(x)` | Identity | `x` |
| `pipe(x, f)` | Apply `f` to `x` | `f(x)` |
| `compose(f, g)` | Right-to-left composition | `\|x\| f(g(x))` |
| `curry(f)` | Turn `f(a, b)` into `f(a)(b)` | `\|a\| \|b\| f(a, b)` |
| `uncurry(h)` | Turn `h(a)(b)` into `h(a, b)` | `\|a, b\| h(a)(b)` |

They are generic and work with any types.

## Example: composition

```wfr
fn inc(x: i32) -> i32 = x + 1
fn double(x: i32) -> i32 = x * 2
fn square(x: i32) -> i32 = x * x

fn main() -> i32 {
    let f = compose(inc, double)   // inc(double(x))
    let g = compose(double, square) // double(square(x))
    let a = f(5)    // inc(double(5)) = inc(25) = 26
    let b = g(3)    // double(square(3)) = double(9) = 18
    return a + b    // 44
}
```

## Example: currying

```wfr
fn add(a: i32, b: i32) -> i32 = a + b

fn main() -> i32 {
    let add_five = curry(add)(5)   // |b| add(5, b)
    return add_five(3)             // 8
}
```

## Pipeline + prelude together

```wfr
fn main() -> i32 {
    let data = [1, 2, 3, 4, 5]
    // pipeline style
    let result = 3 |> inc |> double |> square
    return result   // square(double(inc(3))) = square(8) = 64
}
```

## Why this matters

All of these are **zero-cost**: `compose`, `curry`, and closures monomorphize
to stack-allocated env records and direct function calls. There is no heap
allocation, no boxing, and no runtime reflection. You get a functional style
with imperative performance.

## Next

Read `core/10_comptime.md` to learn about compile-time metaprogramming and
generics — Wolframite's replacement for macros and templates.
