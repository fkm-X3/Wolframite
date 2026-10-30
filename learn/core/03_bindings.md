# 03. Bindings: `let` and `mut`

Wolframite is **immutable by default**. A binding created with `let` cannot be
reassigned. To make a binding changeable, you must declare it explicitly with
`mut`.

## `let` — immutable binding

```wfr
let x: i32 = 42      // annotated type
let y = 10           // type inferred: i32
let name = "Ada"     // type inferred: String
```

Once bound, `x`, `y`, and `name` cannot change:

```wfr
let x = 42
x = 43               // ERROR: cannot assign to immutable binding `x`
```

Function parameters are also immutable by default:

```wfr
fn add(a: i32, b: i32) -> i32 {
    // a = 5   // ERROR: parameter `a` is immutable
    return a + b
}
```

## `mut` — mutable binding

```wfr
mut count: i32 = 0
count = count + 1    // OK: `count` is mutable
count = 5            // OK
```

You cannot re-declare a `mut` binding with `let` in the same scope, and you
cannot assign to a `let` binding even if you later want it mutable. Choose
`let` or `mut` at declaration time.

## Assignment vs. declaration

`let name = expr` and `mut name = expr` are **declarations** — they introduce a
new binding. A bare `name = expr` (without `let`/`mut`) is an **assignment** to
an existing `mut` binding:

```wfr
mut n: i32 = 1
n = 2                // assignment to existing binding
let n = 3            // ERROR: `n` already declared in this scope
```

There is no `:=` token. The keyword (`let`/`mut`) is what makes it a
declaration.

## Type annotations are optional

If you omit the type, the compiler infers it from the initializer:

```wfr
let x = 42        // i32
let pi = 3.14     // f64
let s = "hi"      // String
```

You can still annotate when you want to be explicit or when inference is
ambiguous:

```wfr
let x: i64 = 42
let flag: bool = true
```

## Discarding values with `_`

Use `_` as a binding name when you don't care about the value:

```wfr
let _ = some_function()   // call for side effects, discard result
```

`_` is also a wildcard pattern in `match` (see `core/06_control_flow.md`) and a
hole in pipelines (see `core/09_pipeline.md`).

## Shadowing

You can shadow a binding in an inner scope by declaring a new one with the same
name:

```wfr
let x = 1
{
    let x = 2        // shadows outer `x` inside this block
    print(x)         // prints 2
}
print(x)             // prints 1
```

## Why immutable by default?

It makes programs easier to reason about: when you see `let`, you know the
value won't change. Mutation is opt-in and explicit, so you can spot every
place state changes just by looking for `mut` and assignment.

## Example

```wfr
fn main() -> i32 {
    let limit: i32 = 10
    mut total: i32 = 0
    mut i: i32 = 0
    while i <= limit {
        total = total + i
        i = i + 1
    }
    return total    // 55
}
```

## Next

Read `core/04_functions.md` to learn about functions, fn types, and first-class
fn values.
