# Project 03: 2D Geometry

**Difficulty:** Easy  
**Teaches:** `struct`, struct initializers, field access, free functions, pipelines.

## Goal

Model 2D points and vectors, compute distances and midpoints, and print results.

## What you'll learn

- Declaring a `struct` with fields.
- Initializing with `Point{ .x = ..., .y = ... }`.
- Accessing fields with `.x` / `.y`.
- Writing free functions that take structs (no methods!).
- The `|>` pipeline operator.

## The program

Create `projects/03_geometry/geometry.wfr`:

```wfr
struct Point {
    x: i32,
    y: i32,
}

fn add(p1: Point, p2: Point) -> Point {
    return Point{ .x = p1.x + p2.x, .y = p1.y + p2.y }
}

fn sub(p1: Point, p2: Point) -> Point {
    return Point{ .x = p1.x - p2.x, .y = p1.y - p2.y }
}

fn distance_sq(p: Point) -> i32 {
    return p.x * p.x + p.y * p.y
}

fn midpoint(p1: Point, p2: Point) -> Point {
    return Point{ .x = (p1.x + p2.x) / 2, .y = (p1.y + p2.y) / 2 }
}

fn main() -> i32 {
    let a = Point{ .x = 0, .y = 0 }
    let b = Point{ .x = 3, .y = 4 }

    // free function calls
    let c = add(a, b)            // (3, 4)
    let d = sub(b, a)            // (3, 4)
    let m = midpoint(a, b)       // (1, 2)
    let d2 = distance_sq(c)      // 25

    // pipeline style
    let e = a |> add(b)          // same as add(a, b)
    let f = e |> sub(b)          // same as sub(e, b)

    print("c = (")
    print(c.x)
    print(", ")
    print(c.y)
    print(")")
    print("distance_sq(c) = ")
    print(d2)
    return 0
}
```

## Build and run

```sh
zig build ore -- run projects/03_geometry/geometry.wfr
```

## What to try

1. Add a `scale(p: Point, s: i32) -> Point` function that multiplies both
   fields by `s`.
2. Add a `negate(p: Point) -> Point` function.
3. Use `|>` to chain operations: `a |> add(b) |> negate`.

## Checkpoint

- [ ] `add`, `sub`, `midpoint`, `distance_sq` all produce correct values.
- [ ] You can call them both as `fn(args)` and as `arg |> fn(args)`.
- [ ] Struct field access with `.x` and `.y` works.

## Next

`projects/04_state_machine.md` — enums and `match` for a simple state machine.
