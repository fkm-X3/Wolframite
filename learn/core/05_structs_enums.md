# 05. Structs and Enums

Wolframite has two ways to define your own types: `struct` (product types —
pure data) and `enum` (sum types — a value that is one of several variants).

## Structs — pure data

A `struct` is a bundle of fields. It holds data only — there are no methods,
no `self`, no `impl` blocks. Behavior lives in free functions that take the
struct as a parameter.

```wfr
struct Vec2 {
    x: i32,
    y: i32,
}

fn add(v1: Vec2, v2: Vec2) -> Vec2 {
    return Vec2{ .x = v1.x + v2.x, .y = v1.y + v2.y }
}

fn length_sum(v: Vec2) -> i32 {
    return v.x + v.y
}

fn main() -> i32 {
    let v1 = Vec2{ .x = 1, .y = 2 }
    let v2 = Vec2{ .x = 3, .y = 4 }
    let v3 = add(v1, v2)
    return length_sum(v3)   // 10
}
```

### Struct initialization

Use `TypeName{ .field = value, ... }`. Field order is free, and **all fields
are required** (there are no defaults):

```wfr
let v = Vec2{ .y = 4, .x = 1 }   // OK: order doesn't matter
// let v2 = Vec2{ .x = 1 }        // ERROR: missing field `y`
```

Generic structs are covered in `core/10_comptime.md`.

### Structs are plain aggregates

A struct is just its fields laid out in memory — no vtable pointer, no
reference count, no hidden fields. Passing a struct to a function copies it.

## Enums — sum types

An `enum` defines a value that is one of several named variants. Variants may
carry payloads:

```wfr
enum Color {
    Red,
    Green,
    Blue,
}

enum Option[T] {
    Some(T),
    None,
}

enum Result[T, E] {
    Ok(T),
    Err(E),
}
```

- `Color` has three variants with no payload.
- `Option[T]` is generic: `Some(T)` carries a value, `None` carries nothing.
- `Result[T, E]` represents success (`Ok(T)`) or failure (`Err(E)`).

### Matching on enums

Use `match` to handle each variant. `match` is an expression — each arm yields
a value:

```wfr
fn color_code(c: Color) -> i32 {
    return match c {
        Red => 1,
        Green => 2,
        Blue => 3,
    }
}

fn describe(r: Result[i32, String]) -> i32 {
    return match r {
        Ok(v) => v,        // bind the payload to `v`
        Err(e) => 0,       // ignore the error payload
    }
}
```

Patterns:
- `Red` — literal variant match.
- `Ok(v)` — variant with payload, bind payload to `v`.
- `_` — wildcard, matches anything.

`match` must be **exhaustive** — every possible variant must be handled, or
you must use `_` as a catch-all.

```wfr
fn classify(x: i32) -> String {
    return match x {
        0 => "zero",
        1 => "one",
        _ => "other",      // catch-all
    }
}
```

## Structs vs. enums — when to use which

| Use `struct` when | Use `enum` when |
|---|---|
| You want to group related fields | A value is one of several distinct cases |
| You have "a point with x and y" | You have "success or error", "red/green/blue" |
| Data is always present together | Only one variant is present at a time |

## Combining structs and enums

You can put enums inside structs and structs inside enum payloads:

```wfr
struct Point {
    x: i32,
    y: i32,
}

enum Shape {
    Circle(Point),
    Rect(Point, Point),
}

fn area(s: Shape) -> f64 {
    return match s {
        Circle(c) => 3.14 * c.x * c.x,
        Rect(p1, p2) => (p2.x - p1.x) * (p2.y - p1.y),
    }
}
```

## Next

Read `core/06_control_flow.md` to learn `if`, `while`, `for`, and `match` in
depth.
