# 02. Syntax Basics

A Wolframite source file is one **module**. The file name becomes the module
name (e.g. `math.wfr` is module `math`). A module is a sequence of declarations:

```wfr
// math.wfr
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

let pi: f64 = 3.14
```

## Comments

`//` starts a comment that runs to the end of the line. There are no block
comments.

```wfr
// This is a comment
let x = 42 // inline comment
```

## Tokens

Wolframite's keywords are:

```
fn let mut struct enum return if else while for in
match import as defer true false null comptime move region
```

- `true`/`false` are keyword literals.
- `null` is the unit/null literal.

Punctuation and operators:

```
( ) { } [ ]       delimiters
: ; ,             separators
.  field access   ..  range
-> return/arrow   => match arm / block arrow
|> pipeline       | bit-or / closure delimiter
? error propagation & ref / bit-and   &mut mut ref
@ comptime builtin prefix
= assignment      == != < > <= >=
+ - * / % << >> & | ^ ~ ! && ||
+= -= *= /=       compound assignment
```

## Literals

- Integers: `42`, `0x2A` (hex), `0b101010` (binary), `0o52` (octal). Parsed base-0.
- Floats: `3.14`, `1.5e2`.
- Strings: `"hello"` (double-quoted).
- Chars: `'A'` (single-quoted).

## Identifiers

Start with a letter or `_`, then letters, digits, or `_`:

```wfr
let my_var = 1
let _discard = 2
```

## Newlines are statement separators

Like Python, a newline ends a statement. `;` is an accepted synonym. Inside
`( )`, `[ ]`, `{ }` the parser skips newlines, so you can write multi-line
struct initializers and function bodies freely.

```wfr
let v = Vec2{
    .x = 1,
    .y = 2,
}
```

## Program structure

A module contains declarations. Each declaration is one of:

- `fn` — function declaration
- `struct` — pure-data struct
- `enum` — sum type
- `import` — import another module
- `comptime` — top-level compile-time code
- `let` — top-level binding

Every file needs a `fn main()` to be a runnable program:

```wfr
fn main() -> i32 {
    print("Hello, world!")
    return 0
}
```

`main` takes no arguments and returns `i32` (the exit code). `print` is the
built-in IO prelude function that writes a string plus a newline to stdout.

## Types you will see early

| Type | Meaning | Example |
|---|---|---|
| `i32` | 32-bit signed integer | `42` |
| `f64` | 64-bit float | `3.14` |
| `String` | UTF-8 string | `"hi"` |
| `bool` | `true` or `false` | `true` |
| `null` | unit / "nothing" | `null` |

There are also `i8`, `i16`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`.

## Your first program

Create `hello.wfr`:

```wfr
fn main() -> i32 {
    print("Hello, world!")
    return 0
}
```

Run it:

```sh
zig build ore -- run hello.wfr
```

You should see:

```
Hello, world!
```

## Next

Read `core/03_bindings.md` to learn about `let`, `mut`, and immutability.
