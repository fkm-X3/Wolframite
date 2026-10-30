# 11. Memory: Regions, RAII, and Explicit Allocation

Wolframite has **no garbage collector** and **no borrow checker**. Memory is
managed deterministically through two mechanisms:

1. **RAII** — values are destroyed exactly when they leave scope.
2. **Regions** — `region name { ... }` creates an arena freed at block exit.

## RAII: destruction at scope exit

Every value is dropped (its memory freed) when it leaves the block where it was
declared. Drop order is reverse declaration order:

```wfr
fn main() -> i32 {
    let a = make_value()   // created first
    let b = make_value()   // created second
    // b drops first, then a, when main returns
    return 0
}
```

There are no `async` finalizers, no tracing pauses, and no non-deterministic
cleanup. You can see exactly when each allocation ends by looking at scope
boundaries.

## Regions: arena allocation

`region name { ... }` creates an arena. Allocations inside go into that arena
and are freed when the region block exits:

```wfr
fn main() -> i32 {
    region arena {
        let buf = allocate(1024)   // allocated into `arena`
        // use buf...
    }                               // `arena` freed here — buf is gone
    return 0
}
```

Regions may nest; an inner region is freed before its enclosing region:

```wfr
region outer {
    region inner {
        let x = allocate(64)   // into `inner`
    }                           // `inner` freed here
    let y = allocate(64)       // into `outer`
}                               // `outer` freed here
```

## Explicit allocation control

Allocation is visible in source. You allocate via `region` or explicit
allocator parameters — there is no hidden heap allocation behind your back.
Escaping closures (closures returned from a function) allocate their env record
once, either in the innermost enclosing region or on the heap with an RAII drop.

## No lifetime annotations

Unlike Rust, you never write `'a` or lifetime bounds. The compiler infers
region lifetimes automatically. Function signatures stay lean:

```wfr
fn process(data: String) -> String   // no lifetime parameters needed
```

## What this means in practice

| You write | What happens |
|---|---|
| `let x = value` | `x` drops when it leaves scope |
| `mut x = value` | Same, but `x` can be reassigned |
| `region r { ... }` | Arena allocated, freed at `}` |
| Closure returned from fn | Env allocated once, region-bounded or heap + RAII drop |

## Example: using a region

```wfr
fn main() -> i32 {
    region work {
        mut total: i32 = 0
        for i in 0..100 {
            total = total + i
        }
        print(total)
    }   // `work` arena freed here
    return 0
}
```

## Next

Read `core/12_imports.md` to learn how to split code across modules and import
them.
