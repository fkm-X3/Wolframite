# Project 04: State Machine

**Difficulty:** Medium  
**Teaches:** `enum` sum types, `match`, pattern matching, exhaustive handling.

## Goal

Model a simple traffic light as an enum and write a `next` function that
transitions to the next state. Use `match` to handle each state.

## What you'll learn

- Declaring an `enum` with variants.
- Pattern-matching with `match`.
- Exhaustive matching (every variant handled).
- Returning enum values from functions.

## The program

Create `projects/04_state_machine/traffic.wfr`:

```wfr
enum Light {
    Red,
    Yellow,
    Green,
}

fn next(light: Light) -> Light {
    return match light {
        Red => Green,
        Green => Yellow,
        Yellow => Red,
    }
}

fn name(light: Light) -> String {
    return match light {
        Red => "Red",
        Yellow => "Yellow",
        Green => "Green",
    }
}

fn main() -> i32 {
    mut light: Light = Red

    for i in 0..6 {
        print("Light: ")
        print(name(light))
        print("")
        light = next(light)
    }

    return 0
}
```

## Build and run

```sh
zig build ore -- run projects/04_state_machine/traffic.wfr
```

Expected output cycles: Red → Green → Yellow → Red → ...

## What to try

1. Add a `duration(light: Light) -> i32` function returning how many seconds
   each light stays (Red: 30, Green: 25, Yellow: 5).
2. Add a fourth variant `FlashingRed` and update `next` and `name` — notice
   the compiler reminds you to handle it in every `match` (exhaustiveness).
3. Try removing one arm from `name` and see the compile error about
   non-exhaustive match.

## Checkpoint

- [ ] `next` cycles through all three states correctly.
- [ ] `name` returns the right string for each variant.
- [ ] Adding a new variant forces you to update all `match` expressions
  (exhaustiveness checking works).

## Next

`projects/05_safe_division.md` — `Result`, `?`, and value-oriented error
handling.
