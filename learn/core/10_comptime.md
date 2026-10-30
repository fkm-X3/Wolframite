# 10. Comptime Metaprogramming and Generics

Wolframite does not have macros or templates. Instead, it has **comptime** —
ordinary Wolframite code that runs during compilation — and **comptime
generics**, which are monomorphized (specialized) for each concrete type at
compile time. There is no runtime type information.

## `comptime` blocks

A `comptime` expression or block runs at compile time:

```wfr
comptime {
    let x = 2 + 3        // computed at compile time: 5
    @assert(x == 5, "x should be 5")
}
```

If a comptime condition fails, `@assert` produces a compile error.

## Comptime builtins

These are the `@`-prefixed functions available in comptime contexts:

| Builtin | Meaning |
|---|---|
| `@typeOf(x)` | The type of `x` (a comptime type value) |
| `@sizeOf(T)` | Byte size of type `T` (a `u64`) |
| `@alignOf(T)` | Natural alignment of `T` (a `u64`) |
| `@hasField(T, "name")` | `bool`: true iff struct `T` has field `name` |
| `@field(x, "name")` | Dynamic field access (comptime when `x` is comptime) |
| `@assert(cond [, "msg"])` | Compile error if `cond` is false |

Only these six builtins exist. There is no `@offsetOf`, `@bitSizeOf`, or
enum introspection.

## Generics

Generic functions and structs are templates parameterized by types:

```wfr
fn first[A, B](p: Pair[A, B]) -> A {
    return p.first
}

struct Pair[A, B] {
    first: A,
    second: B,
}
```

When you use `first` with a concrete `Pair[i32, i32]`, the compiler
monomorphizes a version of `first` specialized for `i32, i32`. Type arguments
are often inferred from the call site:

```wfr
let p = Pair{ .first = 10, .second = 20 }   // Pair[i32, i32]
let a = first(p)                             // inferred A=i32, B=i32
```

You can also spell them explicitly: `first[i32, i32](p)`.

## Comptime constraints (replacing interfaces)

Wolframite has no `interface` or `trait` syntax. Instead, you constrain
generics with `comptime` checks inside the function body:

```wfr
fn get_name[T](v: T) -> String {
    comptime @assert(@hasField(T, "name"), "T must have a name field")
    return @field(v, "name")
}

struct Person {
    name: String,
    age: i32,
}

struct Pet {
    name: String,
    species: String,
}

fn main() -> i32 {
    let p = Person{ .name = "Ada", .age = 36 }
    let pet = Pet{ .name = "Fido", .species = "dog" }
    print(get_name(p))     // "Ada"
    print(get_name(pet))   // "Fido"
    return 0
}
```

`get_name` works on any type `T` that has a `name` field, checked at compile
time via `@hasField`. If you call it on a type without `name`, you get a clear
compile error.

## Generic enums

```wfr
enum Option[T] {
    Some(T),
    None,
}

enum Result[T, E] {
    Ok(T),
    Err(E),
}
```

These are used throughout the standard prelude for errors and optional values.

## Key points

- **Comptime is not macros.** You write normal Wolframite code (`let`, `if`,
  `@assert`) that runs while the program is being compiled.
- **Generics monomorphize.** Each concrete instantiation gets its own specialized
  function — no runtime type erasure, no vtables.
- **Constraints are `comptime` checks.** Use `@hasField`, `@sizeOf`, and
  `@assert` inside generic bodies to require capabilities of type parameters.
- **No runtime reflection.** `@typeOf` and friends are compile-time only.

## Example: a generic identity function

```wfr
fn id[T](x: T) -> T {
    return x
}

fn main() -> i32 {
    let a = id(42)           // T inferred as i32
    let b = id("hello")      // T inferred as String
    return a
}
```

## Next

Read `core/11_memory.md` to learn about regions, RAII, and explicit memory
management — Wolframite's alternative to garbage collectors and borrow checkers.
