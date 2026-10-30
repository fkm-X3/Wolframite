# 06. Control Flow

Wolframite has `if`, `else`, `while`, `for`, and `match`. `if` and `match` are
expressions (they produce a value); `while` and `for` are statements.

## `if` expressions

`if` requires braces around bodies and produces a value:

```wfr
fn abs(x: i32) -> i32 = if x > 0 { x } else { -x }
```

You can chain `else if`:

```wfr
fn classify(x: i32) -> i32 {
    return if x < 0 {
        -1
    } else if x == 0 {
        0
    } else {
        1
    }
}
```

Because `if` is an expression, you can assign its result:

```wfr
let label = if x > 0 { "positive" } else { "non-positive" }
```

## `while` loops

```wfr
fn sum_up_to(n: i32) -> i32 {
    mut total: i32 = 0
    mut i: i32 = 0
    while i <= n {
        total = total + i
        i = i + 1
    }
    return total
}
```

The condition is a boolean expression. The body is a block. `while` does not
produce a value.

## `for` loops

There are two forms:

**Numeric range** (`a..b`):

```wfr
mut sum: i32 = 0
for i in 0..10 {
    sum = sum + i
}
```

**Iterate over a value** (over a collection/range value):

```wfr
for item in items {
    print(item)
}
```

The loop variable is immutable inside the body. Use a `mut` binding inside the
body if you need to change a copy.

## `match` expressions

`match` pattern-matches on a value. It is exhaustive — every case must be
covered:

```wfr
enum Result[T, E] {
    Ok(T),
    Err(E),
}

fn unwrap(r: Result[i32, String]) -> i32 {
    return match r {
        Ok(v) => v,
        Err(e) => 0,
    }
}
```

Patterns:
- Literals: `0`, `1`, `"zero"`
- Variant with payload: `Ok(v)`, `Err(e)`, `Some(x)`
- Wildcard: `_` (matches anything)
- Bindings: `v` (binds the whole matched value)

```wfr
fn describe(x: i32) -> String {
    return match x {
        0 => "zero",
        1 => "one",
        _ => "other",
    }
}
```

`match` arms are separated by newlines or commas. A trailing comma is allowed.

## Blocks as expressions

A block `{ ... }` is an expression whose value is the last expression in it:

```wfr
let y = {
    let a = 1
    let b = 2
    a + b   // 3 — this is the block's value
}
```

## `defer` — run cleanup at scope exit

`defer expr` runs `expr` when the current scope exits (like RAII):

```wfr
fn main() -> i32 {
    let f = open_file("data.txt")
    defer close_file(f)   // runs when main returns
    // ... use f ...
    return 0
}
```

Multiple `defer` statements run last-in-first-out (LIFO).

## Example: putting it together

```wfr
fn main() -> i32 {
    mut total: i32 = 0
    for i in 1..=5 {        // note: ranges are exclusive on the right (0..10 = 0..9)
        total = total + i
    }
    let result = if total > 10 { "big" } else { "small" }
    print(result)
    return 0
}
```

## Next

Read `core/07_errors.md` to learn about `Result`/`Option` and the postfix `?`
operator — Wolframite's approach to error handling without exceptions.
