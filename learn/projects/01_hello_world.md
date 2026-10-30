# Project 01: Hello, World

**Difficulty:** Easy  
**Teaches:** Program structure, `fn main`, `print`, building and running.

## Goal

Print `Hello, world!` to the screen and exit with code 0.

## What you'll learn

- A Wolframite file is a module.
- Every runnable program needs `fn main() -> i32`.
- `print` writes a string plus a newline to stdout.
- How to compile and run with `ore`.

## The program

Create `projects/01_hello_world/hello.wfr`:

```wfr
fn main() -> i32 {
    print("Hello, world!")
    return 0
}
```

## Build and run

```sh
zig build ore -- run projects/01_hello_world/hello.wfr
```

You should see:

```
Hello, world!
```

Or build an executable:

```sh
zig build ore -- build --emit-bin projects/01_hello_world/hello.wfr
./hello            # Linux
hello.exe          # Windows
```

## What's happening

- `fn main() -> i32` — the entry point. It returns an exit code (0 = success).
- `print("Hello, world!")` — the built-in IO prelude function. Writes the
  string to stdout followed by a newline.
- `return 0` — exit code 0.

## Checkpoint

- [ ] The program prints `Hello, world!`
- [ ] It exits with code 0 (`echo $?` shows 0 on Linux; `$LASTEXITCODE` on Windows)

## Next

`projects/02_calculator.md` — build a small arithmetic calculator.
