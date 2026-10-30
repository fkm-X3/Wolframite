# 04. Functions

Functions are the main unit of behavior in Wolframite. They are **free
functions** — not methods attached to types. There is no `self`, `this`, or
method-call syntax (`obj.method()` does not exist).

## Declaring a function

```wfr
fn add(a: i32, b: i32) -> i32 {
    return a + b
}
```

- `fn` introduces the declaration.
- `add` is the function name.
- `(a: i32, b: i32)` are the parameters (all immutable by default).
- `-> i32` is the return type.
- `{ ... }` is the body.

If a function has no return type, it returns `unit` (the `null` value):

```wfr
fn greet() {
    print("Hello")
}
```

## Single-expression shorthand

A function whose body is a single expression can use `=` instead of a block.
The expression is implicitly returned:

```wfr
fn double(x: i32) -> i32 = x * 2
fn square(x: i32) -> i32 = x * x
```

This is equivalent to:

```wfr
fn double(x: i32) -> i32 {
    return x * 2
}
```

## Calling a function

Call free functions with the name and arguments:

```wfr
let c = add(2, 3)      // 5
let d = double(c)      // 10
```

## Fn types (first-class function values)

Wolframite treats functions as values. The type `fn(A, B) -> R` describes a
function taking `A` and `B` and returning `R`:

```wfr
fn apply(f: fn(i32, i32) -> i32, x: i32, y: i32) -> i32 {
    return f(x, y)
}

fn main() -> i32 {
    return apply(add, 2, 3)   // 5 — `add` coerces to a fn value
}
```

A `fn` name used in value position becomes a function value of its signature
type. Generic function names must be instantiated first (see `core/10_comptime.md`).

## The pipeline operator `|>`

`lhs |> rhs` threads `lhs` into `rhs`. If `rhs` is a call, `lhs` becomes
argument 0 (or fills a `_` hole):

```wfr
let a = 3 |> inc          // inc(3)
let b = 10 |> add(5)      // add(10, 5)
let c = 10 |> add(_, 3)   // add(10, 3)  (hole filled by the piped value)
let d = 3 |> inc |> double // double(inc(3)) == 8
```

Pipelines are left-associative and bind loosely, so `3 |> inc |> double` reads
naturally as "3, then inc, then double."

## Function values as data

A function value is a 16-byte pair `{ fn_ptr, env_ptr }`. You can store it in a
struct field, pass it around, and call it later:

```wfr
fn call_twice(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x) + f(x)
}

fn main() -> i32 {
    return call_twice(inc, 5)   // 6 + 6 = 12
}
```

Closures (anonymous functions that capture variables) are covered in
`core/08_closures.md`.

## Example: a small math module

```wfr
fn add(a: i32, b: i32) -> i32 = a + b
fn sub(a: i32, b: i32) -> i32 = a - b
fn mul(a: i32, b: i32) -> i32 = a * b

fn main() -> i32 {
    let a = add(2, 3)
    let b = mul(4, 5)
    return sub(b, a)   // 20 - 5 = 15
}
```

## Next

Read `core/05_structs_enums.md` to learn about pure-data structs and enum sum
types.
