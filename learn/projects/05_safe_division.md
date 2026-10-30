# Project 05: Safe Division

**Difficulty:** Medium  
**Teaches:** `Result[T, E]`, `Ok`/`Err`, postfix `?`, error propagation, `match`.

## Goal

Write a division function that can fail (division by zero), chain several
divisions with `?`, and match on the final result.

## What you'll learn

- `Result[T, E]` as a sum type.
- Constructing `Ok(value)` and `Err(error)`.
- The `?` operator: unwrap or early-return the error.
- Handling the result with `match`.

## The program

Create `projects/05_safe_division/div.wfr`:

```wfr
enum Result[T, E] {
    Ok(T),
    Err(E),
}

fn divide(a: i32, b: i32) -> Result[i32, String] {
    if b == 0 {
        return Err("division by zero")
    }
    return Ok(a / b)
}

fn compute(a: i32, b: i32, c: i32) -> Result[i32, String] {
    let x = divide(a, b)?
    let y = divide(x, c)?
    return Ok(y + 1)
}

fn main() -> i32 {
    let ok = compute(100, 5, 2)
    match ok {
        Ok(v) => print("Ok: "),
        Err(e) => print("Err: "),
    }

    let bad = compute(100, 0, 2)
    match bad {
        Ok(v) => print("Ok: "),
        Err(e) => print("Err: "),
    }

    return 0
}
```

## Build and run

```sh
zig build ore -- run projects/05_safe_division/div.wfr
```

- `compute(100, 5, 2)` → `divide(100,5)=Ok(20)`, `divide(20,2)=Ok(10)`, `Ok(11)`.
- `compute(100, 0, 2)` → `divide(100,0)=Err(...)`, `?` propagates the error.

## What to try

1. Add a `divide_chain(a: i32, divisors: []i32) -> Result[i32, String]` that
   divides `a` by each element using a loop and `?`.
2. Try `compute(100, 5, 0)` — the second divide fails. Verify `?` propagates.
3. Write a `safe_sqrt` style function that returns `Err` on negative input.

## Checkpoint

- [ ] `divide` returns `Ok` on success, `Err` on division by zero.
- [ ] `?` unwraps `Ok` and early-returns `Err`.
- [ ] `compute` with valid inputs returns the right value; with zero divisor
  returns the error.

## Next

`projects/06_generic_container.md` — generics with `Pair` and `Option`.
