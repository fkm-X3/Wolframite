# Project 08: Comptime Generics

**Difficulty:** Hard  
**Teaches:** `comptime`, `@hasField`, `@assert`, generic constraints, `print`.

## Goal

Write a generic `get_name[T]` function that works on any struct with a `name`
field, using `@hasField` as a compile-time constraint.

## What you'll learn

- `comptime` blocks run at compile time.
- `@hasField(T, "name")` checks whether a struct type has a field.
- `@assert(cond, "msg")` produces a compile error if the constraint fails.
- `@field(v, "name")` reads a field dynamically at compile time.
- Generic functions constrained by comptime checks (Wolframite's replacement
  for interfaces/traits).

## The program

Create `projects/08_comptime_generics/get_name.wfr`:

```wfr
struct Person {
    name: String,
    age: i32,
}

struct Pet {
    name: String,
    species: String,
}

struct Point {
    x: i32,
    y: i32,
}

// Works on any type T that has a "name" field
fn get_name[T](v: T) -> String {
    comptime @assert(@hasField(T, "name"), "T must have a name field")
    return @field(v, "name")
}

fn main() -> i32 {
    let p = Person{ .name = "Ada", .age = 36 }
    let pet = Pet{ .name = "Fido", .species = "dog" }

    print(get_name(p))     // "Ada"
    print("")
    print(get_name(pet))   // "Fido"
    print("")

    // Uncommenting this should be a COMPILE ERROR:
    // Point has no "name" field
    // let pt = Point{ .x = 1, .y = 2 }
    // print(get_name(pt))

    return 0
}
```

## Build and run

```sh
zig build ore -- run projects/08_comptime_generics/get_name.wfr
```

Expected output:
```
Ada
Fido
```

## What to try

1. Uncomment the `Point` lines and try to build. You should get a compile
   error like `T must have a name field`. This is the constraint working.
2. Add a `struct Car { name: String, year: i32 }` and call `get_name` on it —
   it should work because `Car` has a `name` field.
3. Write `get_age[T](v: T) -> i32` constrained on `@hasField(T, "age")` and
   call it on `Person`.
4. Try `@sizeOf(T)` and `@alignOf(T)` inside a comptime block to print type
   sizes at compile time.

## Checkpoint

- [ ] `get_name` works on `Person` and `Pet` (both have `name`).
- [ ] `get_name` fails to compile on `Point` (no `name` field).
- [ ] You understand that the check happens at compile time, not runtime.

## Next

`projects/09_multi_module.md` — splitting code across modules with `import`.
