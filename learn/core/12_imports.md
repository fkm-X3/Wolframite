# 12. Modules and Imports

A Wolframite source file is one **module**. The module name is derived from the
file path. You use `import` to bring symbols from another module into scope.

## Import syntax

```wfr
import math                  // import module `math`, use `math::name`
import utils as u            // import `utils`, refer to it as `u`
import os::path              // import `os::path`, refer to it as `path`
```

After importing, you access the module's public symbols through its name (or
alias):

```wfr
import math

fn main() -> i32 {
    let r = math::abs(-5)
    return r
}
```

## What can be imported

Functions, structs, enums, and top-level bindings declared in another module
are accessible through the module qualifier. There is no `public`/`private`
keyword — module-level symbols are accessible via their module path.

## Example: a multi-module program

`geometry.wfr`:

```wfr
struct Point {
    x: i32,
    y: i32,
}

fn distance(a: Point, b: Point) -> f64 {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy)  // simplified
}
```

`main.wfr`:

```wfr
import geometry

fn main() -> i32 {
    let a = geometry.Point{ .x = 0, .y = 0 }
    let b = geometry.Point{ .x = 3, .y = 4 }
    let d = geometry::distance(a, b)
    return 0
}
```

## Aliasing imports

Use `as` when a module name is long or conflicts with a local name:

```wfr
import very_long_module_name as v
let x = v::some_function()
```

## `main` is special

Each executable needs exactly one `fn main()`. Imported modules can contain
their own functions but do not need a `main` — only the entry module does.

## Next

You have finished the core concepts. Move on to the projects in
`learn/projects/`, starting with `projects/01_hello_world.md`. The projects
reinforce everything you learned above by having you write real programs.
