# Project 02: Calculator

**Difficulty:** Easy  
**Teaches:** Functions, bindings, arithmetic, `mut`, loops, `print`.

## Goal

Build a small calculator that reads a starting value, applies a series of
operations (add, subtract, multiply, divide), and prints the result.

## What you'll learn

- Declaring and calling free functions.
- `let` and `mut` bindings.
- Arithmetic operators (`+ - * /`).
- A `while` loop for repeated operations.
- Converting the result to a string for printing.

## The program

Create `projects/02_calculator/calc.wfr`:

```wfr
fn add(a: i32, b: i32) -> i32 = a + b
fn sub(a: i32, b: i32) -> i32 = a - b
fn mul(a: i32, b: i32) -> i32 = a * b
fn div(a: i32, b: i32) -> i32 = a / b

fn main() -> i32 {
    mut result: i32 = 10
    mut i: i32 = 0

    result = add(result, 5)    // 15
    result = sub(result, 3)    // 12
    result = mul(result, 2)    // 24
    result = div(result, 4)    // 6

    while i < 3 {
        result = add(result, 1)
        i = i + 1
    }

    print("Result: ")
    print(result)          // note: print takes a String; see below
    return 0
}
```

## About printing numbers

`print` takes a `String`. To print an integer, convert it first. For this
project you can use a helper that builds a simple string, or just print the
final result using a string buffer. A minimal approach:

```wfr
fn i32_to_string(n: i32) -> String {
    // ... build a string from the integer
}
```

If your compiler version doesn't have int-to-string yet, print a fixed message
and use the exit code to see the result:

```wfr
fn main() -> i32 {
    // ... compute result ...
    return result          // exit code is the result
}
```

Then check with `echo $?` (Linux) or `$LASTEXITCODE` (Windows) after running.

## Build and run

```sh
zig build ore -- run projects/02_calculator/calc.wfr
```

## Checkpoint

- [ ] The calculator compiles and runs.
- [ ] The result is correct: `10 + 5 - 3 = 12`, `* 2 = 24`, `/ 4 = 6`, `+ 3 = 9`.
- [ ] You can change the starting value and operations and get a new result.

## Next

`projects/03_geometry.md` — structs and free functions for 2D geometry.
