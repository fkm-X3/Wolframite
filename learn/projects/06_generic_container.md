# Project 06: Generic Container

**Difficulty:** Medium  
**Teaches:** Generic structs, generic functions, type inference, `Option`.

## Goal

Build a generic `Pair[A, B]` struct and a generic `first`/`swap` function,
then use them with different type combinations.

## What you'll learn

- Generic structs: `struct Pair[A, B] { ... }`.
- Generic functions: `fn first[A, B](...) -> A`.
- Type inference at call sites.
- `Option[T]` for optional values.

## The program

Create `projects/06_generic_container/pair.wfr`:

```wfr
struct Pair[A, B] {
    first: A,
    second: B,
}

enum Option[T] {
    Some(T),
    None,
}

fn first[A, B](p: Pair[A, B]) -> A {
    return p.first
}

fn second[A, B](p: Pair[A, B]) -> B {
    return p.second
}

fn swap[A, B](p: Pair[A, B]) -> Pair[B, A] {
    return Pair{ .first = p.second, .second = p.first }
}

fn main() -> i32 {
    let p1 = Pair{ .first = 10, .second = 20 }      // Pair[i32, i32]
    let p2 = Pair{ .first = "hi", .second = 42 }    // Pair[String, i32]

    let a = first(p1)                               // 10
    let b = second(p2)                              // 42
    let p3 = swap(p1)                               // Pair{ .first = 20, .second = 10 }

    let c = first(p3)                               // 20

    // Option usage
    let opt: Option[i32] = Some(7)
    let val = match opt {
        Some(v) => v,
        None => -1,
    }

    return a + b + c + val   // 10 + 42 + 20 + 7 = 79
}
```

## Build and run

```sh
zig build ore -- run projects/06_generic_container/pair.wfr
```

The compiler infers `A` and `B` from the struct initializer and function
arguments — you usually don't write `[i32, i32]` explicitly.

## What to try

1. Add a generic `pair_map[A, B, C](p: Pair[A, B], f: fn(A) -> C) -> Pair[C, B]`
   that applies `f` to the first field.
2. Create a `Pair[String, String]` and use `first`/`second` on it.
3. Write a function `unwrap_or[T](o: Option[T], default: T) -> T` that returns
   the value or the default.

## Checkpoint

- [ ] `Pair` works with different type combinations (`i32,i32`, `String,i32`).
- [ ] `first`, `second`, `swap` return correct values.
- [ ] `Some`/`None` match works and returns the right value.

## Next

`projects/07_functional_pipeline.md` — closures, `|>`, and `compose`.
