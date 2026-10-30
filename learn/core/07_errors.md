# 07. Value-Oriented Errors

Wolframite has **no exceptions**. Errors are ordinary values carried in enum
sum types: `Result[T, E]` and `Option[T]`.

## `Result[T, E]`

```wfr
enum Result[T, E] {
    Ok(T),
    Err(E),
}
```

`Ok(T)` holds a successful value; `Err(E)` holds an error. A function that can
fail returns a `Result`:

```wfr
fn divide(a: i32, b: i32) -> Result[i32, String] {
    if b == 0 {
        return Err("division by zero")
    }
    return Ok(a / b)
}
```

Callers use `match` to handle both outcomes:

```wfr
fn main() -> i32 {
    let r = divide(10, 2)
    return match r {
        Ok(v) => v,
        Err(e) => 0,
    }
}
```

## `Option[T]`

```wfr
enum Option[T] {
    Some(T),
    None,
}
```

`Some(T)` holds a value; `None` means "absent":

```wfr
fn find(names: []String, target: String) -> Option[i32] {
    // ... returns Some(index) or None
}
```

## The `?` operator — unwrap or early-return

`x?` is a postfix operator. If `x` is `Ok(v)`/`Some(v)`, it evaluates to `v`.
If `x` is `Err(e)`/`None`, it **returns early** from the enclosing function
with the error:

```wfr
fn compute(a: i32, b: i32, c: i32) -> Result[i32, String] {
    let x = divide(a, b)?     // if divide returns Err, return that Err immediately
    let y = divide(x, c)?     // same here
    return Ok(y + 1)
}
```

The `?` operator compiles to a simple branch-to-return — no exception unwinding,
no runtime cost beyond a conditional branch.

### Rule: the enclosing function must return the same enum

You can only use `?` in a function whose return type is the same `Result`/`Option`
declaration. `?` propagates the error variant of the enclosing function's return
type:

```wfr
fn compute(a: i32, b: i32) -> Result[i32, String] {
    let x = divide(a, b)?     // OK: both return Result[i32, String]
    return Ok(x)
}
```

If the error types don't match, you handle the mismatch at the call site with
`match` instead of `?`.

## Example: safe division chain

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
    let r = compute(100, 5, 2)
    return match r {
        Ok(v) => v,    // 21
        Err(e) => 0,   // error path
    }
}
```

`compute(100, 5, 2)` → `divide(100, 5) = Ok(20)` → `divide(20, 2) = Ok(10)` →
`Ok(10 + 1) = Ok(11)`. Returns 11.

`compute(100, 0, 2)` → `divide(100, 0) = Err("division by zero")` → `?`
propagates that error. Returns 0 via the `Err` arm.

## Why this design?

- **No exceptions** means no hidden control flow — every error path is visible
  in the source via `match` or `?`.
- **No runtime cost** beyond a branch — `?` is a conditional branch-to-return,
  not an unwind table.
- **Explicit in signatures** — a function returning `Result[i32, String]` tells
  you exactly how it can fail.

## Next

Read `core/08_closures.md` to learn about closures — anonymous functions that
capture variables from their surroundings.
