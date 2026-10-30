# Project 07: Functional Pipeline

**Difficulty:** Medium  
**Teaches:** Closures, `|>` pipeline, `compose`, `curry`, first-class fn values.

## Goal

Build a small data-processing pipeline: transform a number through a series of
steps using closures, the pipeline operator, and composition.

## What you'll learn

- Closure literals `|x| ...`.
- Capturing variables from the enclosing scope.
- The `|>` pipeline operator with argument 0 and `_` hole.
- `compose` and `curry` from the prelude.
- Passing functions as values to higher-order functions.

## The program

Create `projects/07_functional_pipeline/pipe.wfr`:

```wfr
fn inc(x: i32) -> i32 = x + 1
fn double(x: i32) -> i32 = x * 2
fn square(x: i32) -> i32 = x * x

fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

fn main() -> i32 {
    let base = 10

    // A closure capturing `base`
    let add_base = |x| x + base

    // Pipeline: 5 |> add_base = add_base(5) = 15
    let step1 = 5 |> add_base

    // Pipeline with hole: 10 |> add(_, 3) = add(10, 3) = 13
    let step2 = 10 |> add_base(_, 3)   // = add_base(10) + ... depends on signature

    // Compose: inc(double(x))
    let f = compose(inc, double)
    let step3 = f(4)   // inc(double(4)) = inc(8) = 9

    // Curry: curry(add)(5) returns |b| add(5, b)
    let add_five = curry(add)
    let step4 = add_five(7)   // 12

    // Pass a closure as a fn value
    let step5 = apply(double, 6)   // 12

    return step1 + step2 + step3 + step4 + step5
}
```

## Build and run

```sh
zig build ore -- run projects/07_functional_pipeline/pipe.wfr
```

## What to try

1. Write `make_multiplier(factor: i32) -> fn(i32) -> i32` returning a closure
   that multiplies by `factor`.
2. Build a pipeline `|>` with at least 4 steps: inc → double → square →
   add_base.
3. Use `compose(double, square)` and `compose(square, double)` and confirm they
   give different results.

## Checkpoint

- [ ] A closure captures a variable from its enclosing scope.
- [ ] `|>` works with both `f(x)` (arg 0) and `f(_, x)` (hole) forms.
- [ ] `compose` and `curry` produce correct results.
- [ ] A closure can be passed as a `fn(i32) -> i32` value.

## Next

`projects/08_comptime_generics.md` — comptime constraints with `@hasField`.
