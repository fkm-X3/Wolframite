# Project 09: Multi-Module Program

**Difficulty:** Medium  
**Teaches:** `import`, module aliases, splitting code across files.

## Goal

Split a program into multiple modules: a `math` module with arithmetic
functions, a `shapes` module with `Point` and distance, and a `main` module
that imports and uses both.

## What you'll learn

- `import math` — import a module.
- `import utils as u` — import with an alias.
- `import os::path` — namespace import.
- Accessing symbols via `module::name`.
- Each file is one module; `main` is the entry point.

## The program

Create three files:

**projects/09_multi_module/math.wfr:**

```wfr
fn add(a: i32, b: i32) -> i32 = a + b
fn sub(a: i32, b: i32) -> i32 = a - b
fn mul(a: i32, b: i32) -> i32 = a * b
```

**projects/09_multi_module/shapes.wfr:**

```wfr
struct Point {
    x: i32,
    y: i32,
}

fn distance_sq(p: Point) -> i32 {
    return p.x * p.x + p.y * p.y
}
```

**projects/09_multi_module/main.wfr:**

```wfr
import math
import shapes as s

fn main() -> i32 {
    let sum = math::add(10, 5)
    let diff = math::sub(10, 5)
    let prod = math::mul(3, 4)

    let p = s.Point{ .x = 3, .y = 4 }
    let d = s.distance_sq(p)

    print("sum: ")
    print(sum)
    print("diff: ")
    print(diff)
    print("prod: ")
    print(prod)
    print("dist_sq: ")
    print(d)

    return 0
}
```

## Build and run

From the `projects/09_multi_module/` directory:

```sh
zig build ore -- run main.wfr
```

(The compiler resolves `math.wfr` and `shapes.wfr` relative to the importing
module's location.)

## What to try

1. Add a `geometry.wfr` module with a `midpoint` function and import it.
2. Use an alias: `import shapes as shp` and call `shp::Point{...}`.
3. Add a top-level binding in `math.wfr` (e.g. `let pi: f64 = 3.14`) and use
   `math::pi` in main.

## Checkpoint

- [ ] `main.wfr` can call functions from both `math` and `shapes`.
- [ ] The alias `s` works for `shapes`.
- [ ] Structs defined in one module can be used in another via the module path.

## Next

`projects/10_bootloader.md` — the final project: an x86 bootloader using the
Ferro linker (not yet possible, but teaches the linker story).
