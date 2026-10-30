# 08. Closures

A **closure** is an anonymous function that captures variables from its
surrounding scope. Closures are written with `|...|`:

```wfr
let add_five = |x| x + 5
let result = add_five(3)   // 8
```

## Closure syntax

```wfr
|x| x + 1                          // expression body, implicit return
|x| { let y = x + 1; y }           // block body
|a: i32, b: i32| a + b             // multiple params with types
|x| x + base                       // captures `base` from the enclosing scope
```

Closure parameters are immutable by default; use `mut` to mutate a captured
binding inside the closure body.

## Capture by value

When a closure uses a variable from outside, it captures that variable **by
value** into a stack-allocated "env record":

```wfr
fn make_adder(base: i32) -> fn(i32) -> i32 {
    return |x| x + base   // captures `base` by value
}

fn main() -> i32 {
    let add_five = make_adder(5)
    return add_five(3)     // 8
}
```

`make_adder(5)` creates a closure whose env record holds `base = 5`. Calling
`add_five(3)` runs the lifted body `x + 5` → `3 + 5 = 8`.

The captured value is a copy, so mutating inside the closure never affects the
outer binding:

```wfr
fn main() -> i32 {
    mut base = 10
    let f = |x| { base = base + 1; x + base }  // captures a COPY of base
    let r1 = f(1)   // base inside env: 11, result 12
    let r2 = f(1)   // base inside env still 11 (copy), result 12
    print(base)     // prints 10 — outer `base` unchanged
    return r1 + r2
}
```

## Closures as first-class values

A closure coerces to a function value `fn(T) -> U`, so it can be passed to
higher-order functions:

```wfr
fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

fn main() -> i32 {
    let add_ten = |x| x + 10
    return apply(add_ten, 4)   // 14
}
```

## Closures returning closures

A closure can return another closure, capturing values through each level:

```wfr
fn make_multiplier(factor: i32) -> fn(i32) -> i32 {
    return |x| x * factor
}

fn main() -> i32 {
    let triple = make_multiplier(3)
    return triple(4)   // 12
}
```

## Nested closures

Closures can nest. An inner closure captures whatever it uses freely, including
the outer closure's parameters:

```wfr
fn main() -> i32 {
    let outer = |x| {
        let inner = |y| x + y
        return inner(5)
    }
    return outer(10)   // 15
}
```

Each capture is a by-value copy, so there are no dangling references or hidden
pointer chains.

## Zero cost

Closures monomorphize down to:
1. A lifted (module-level) function whose free variables become `env.field`
   accesses.
2. An env record built at the closure's creation site.
3. A 16-byte function value `{ fn_ptr, env_ptr }`.

Non-capturing closures carry `env_ptr = 0` and compile to direct calls — no
heap, no boxing.

## Example: closure pipeline

```wfr
fn main() -> i32 {
    let base = 10
    let add_base = |x| x + base
    let double = |x| x * 2
    let result = 5 |> add_base |> double   // double(add_base(5)) = double(15) = 30
    return result
}
```

## Next

Read `core/09_pipeline.md` to learn about the `|>` pipeline operator and the
composition prelude (`compose`, `curry`, `id`, `pipe`).
