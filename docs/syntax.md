# Wolframite Syntax Specification

The **target** grammar for the functional-imperative rewrite. The header table below ties
each surface feature to the language constraint it satisfies.

## 1. Design constraints that shape the grammar

The syntax must express:

| Constraint | Syntax consequence |
|---|---|
| **Immutable by default** | `let` (immutable binding) vs `mut` (explicit mutable); fn params immutable; assignment only to `mut` bindings |
| **No OOP class hierarchy** | no `class`, `interface`, `impl`, `Self`, vtables, hidden `this` |
| **Compile-time metaprogramming** | `comptime` expressions/blocks; comptime builtins `@name(...)` |
| **Value-oriented errors** | `Result[T, E]` / `Option[T]` sum types + `match` + postfix `?` |
| **Zero-cost functional abstractions** | fn types `fn(T) -> U`, fn-name-as-value, closures `|...|`, pipeline `|>`, prelude `compose`/`curry`/`id` |
| **No lifetime annotations** | no `'a`-style syntax anywhere |
| **Regions / explicit allocation** | `region name { ... }` arena scope, explicit allocator params |

## 2. Token set (target)

The keywords `impl` and `interface` are **de-lexed**: they are no
longer keywords and re-lex as ordinary identifiers. No token grammar depends on them.

### 2.1 Keywords

```
fn  let  mut  struct  enum  return  if  else  while  for  in
match  import  as  defer  true  false  null  comptime  move  region
```

`true`/`false` are keyword literals; `null` is the unit/null literal.

### 2.2 Punctuation & operators

```
( ) { } [ ]                 delimiters
: ; ,                       separators
.   field access            ..  range
->  return/arrow            =>  match arm / block arrow
|>  pipeline                |   bit-or / closure delimiter
?   error propagation       &   ref / bit-and        &mut  mut ref
@   comptime builtin prefix ( '@name', '@name(args)' )
=   assignment (init / assign)    ==  !=  <  >  <=  >=
+ - * / %  <<  >>  &  |  ^  ~  !  &&  ||
+= -= *= /=                       compound assignment
```

Literal lexing: `int_literal`, `float_literal`, `string_literal` (double-quoted),
`char_literal` (single-quoted), identifiers start with a letter or `_`.

## 3. Lexical grammar

```
identifier  ::= [a-zA-Z_][a-zA-Z0-9_]*
int_literal ::= decimal | 0x hex | 0b binary | 0o octal        (parsed base-0)
float_literal ::= digits '.' digits ( [eE] [+-]? digits )?
string_literal ::= '"' chars '"'
char_literal   ::= "'" char "'"
comment     ::= '//' to end of line
newline     ::= physical newline (significant as statement separator)
```

Newlines are statement separators (like Python, unlike C); `;` is an accepted synonym.
Inside `( )` / `[ ]` / `{ }` and between elements the parser skips newlines.

## 4. Surface grammar

`*` = zero-or-more, `+` = one-or-more, `?` = optional, `|` = choice.
Terminals are the tokens of §2. Non-terminals in `<...>`.

### 4.1 Program / module

```
<module>      ::= <decl>*
<decl>        ::= <fn_decl>
                | <struct_decl>
                | <enum_decl>
                | <import_decl>
                | <comptime_stmt>        -- top-level comptime
                | <let_stmt>             -- top-level binding
```

One file = one module; module name is derived from its path (§ `imports.wfr`).

### 4.2 Function declarations

```
<fn_decl>     ::= 'fn' <identifier> <generic_params>? '(' <param_list> ')' <return_ty>? <fn_body>
<generic_params> ::= '[' <identifier> (',' <identifier>)* ']'
<param_list>  ::= ( <param> (',' <param>)* )?
<param>       ::= <identifier> ':' <type_repr>            -- params immutable
<return_ty>   ::= '->' <type_repr>
<fn_body>     ::= '{' <stmt>* '}'                        -- block body
                | '=' <expr>                             -- single-expression shorthand,
                                                           implicit return
```

Examples (from `examples/functions.wfr` target):

```wfr
fn add(a: i32, b: i32) -> i32 { return a + b }
fn double(x: i32) -> i32 = x * 2        // shorthand: implicit `return`
fn greet() { let msg = "hello" }        // no return type = void
```

No return type => unit (`void`) return.

### 4.3 Struct declarations (pure data)

`struct` is **data only**. There is no method syntax, no `self`, no associated
functions. Behavior lives in free functions over the struct.

```
<struct_decl> ::= 'struct' <identifier> <generic_params>? '{' <field>+ '}'
<field>       ::= <identifier> ':' <type_repr>
```

Target for `examples/structs.wfr`:

```wfr
struct Vec2 { x: f64  y: f64 }

fn add(v1: Vec2, v2: Vec2) -> Vec2 { return Vec2{ .x = v1.x + v2.x, .y = v1.y + v2.y } }
fn len(v: Vec2) -> f64 { return v.x * v.x + v.y * v.y }
fn zero() -> Vec2 { return Vec2{ .x = 0.0, .y = 0.0 } }
```

### 4.4 Enum declarations (sum types)

```
<enum_decl>   ::= 'enum' <identifier> <generic_params>? '{' <variant>+ '}'
<variant>     ::= <identifier> ( '(' <type_repr> (',' <type_repr>)* ')' )?
```

Target keeps `examples/enums.wfr` unchanged:

```wfr
enum Option[T]   { Some(T)   None }
enum Result[T, E]{ Ok(T)     Err(E) }
```

### 4.5 Import declarations

```
<import_decl> ::= 'import' <identifier> ( '::' <identifier> )* ( 'as' <identifier> )?
```

`import math`, `import utils as u`, `import os::path` (namespace import re-exported as `path`).
From `examples/imports.wfr`.

### 4.6 Statements & bindings

```
<stmt>        ::= <let_stmt> | <return_stmt> | <expr_stmt>
                | <if_expr> | <while_expr> | <for_stmt> | <match_expr>
                | <block> | <defer_stmt>

<let_stmt>    ::= ('let' | 'mut') <name> (':' <type_repr>)? ('=' <expr>)? <terminator>
<name>        ::= identifier | '_'                       -- `_` discards
<return_stmt> ::= 'return' <expr>?                       -- no value => unit
<expr_stmt>  ::= <expr> <terminator>
<defer_stmt>  ::= 'defer' <expr> <terminator>            -- RAII hook, runs at scope exit
<block>       ::= '{' <stmt>* '}'
<terminator>  ::= newline | ';'
```

`let` = immutable (default), `mut` = explicitly mutable. Bindings are immutable unless `mut`.
Assignment targets only `mut` bindings. There is no `:=` token; `let name = expr` (with type
inference) is the single binding form. From `examples/variables.wfr` target:

```wfr
let x: i32 = 42        // immutable, annotated
mut y: f64 = 3.14      // mutable, annotated; `y = 2.71` allowed later
let z = x + 10         // type inferred: z: i32
```

### 4.7 Control flow

```
<if_expr>     ::= 'if' <expr> <block_or_if> ( 'else' ( 'if' <expr> <block_or_if> | <block> ) )?
<while_expr>  ::= 'while' <expr> <block>
<for_stmt>    ::= 'for' <identifier> 'in' <expr> '..' <expr> <block>     -- numeric range
                | 'for' <identifier> 'in' <expr> <block>                 -- iterate over value
<match_expr>  ::= 'match' <expr> '{' <match_arm> (','? <match_arm>)* ','? '}'
<match_arm>   ::= <pattern> ( 'if' <expr> )? '=>' <expr>
<pattern>     ::= literal | '_' | <identifier>           -- enum variant / binding
                | <identifier> '(' <identifier> ')'     -- variant with payload
```

`if`/`while`/`for` bodies are blocks; braces are required.
`if` and `match` are **expressions** (each arm/body yields a value when used as an expression).
`match` arms are delimited by newlines/commas; arms may share commas.
From `examples/control_flow.wfr`:

```wfr
fn abs(x: i32) -> i32 = if x > 0 { x } else { -x }
fn sum_range() -> i32 {
    mut s: i32 = 0
    for i in 0..10 { s = s + i }
    return s
}
```

From `examples/match.wfr`:

```wfr
fn value_or_default(opt: Option[i32]) -> i32 {
    return match opt {
        Some(v) => v,
        None => -1,
    }
}
```

### 4.8 Expressions (with precedence)

Precedence, loosest→tightest. Assumed left-associative except assignment/arrow-params.

| Level | Operators | Associativity |
|---|---|---|
| 1 pipeline | `|>` | left |
| 2 range | `..` | left |
| 3 assignment | `=` `+=` `-=` `*=` `/=` | **right** |
| 4 logical or | `\|\|` | left |
| 5 logical and | `&&` | left |
| 6 bitwise or | `\|` | left |
| 7 bitwise xor | `^` | left |
| 8 bitwise and | `&` | left |
| 9 equality | `==` `!=` | left |
| 10 comparison | `<` `>` `<=` `>=` | left |
| 11 shift | `<<` `>>` | left |
| 12 term | `+` `-` | left |
| 13 factor | `*` `/` `%` | left |
| 14 prefix | `-` `!` `~` `&` `&mut` `move` `@name` | — |
| 15 postfix | call `(...)`, index `[...]`, field `.x`, `?` | left |
| 16 primary | literals, identifiers, `(expr)`, `{ block }`, closure | — |

(This mirrors the parser's `Precedence` ladder in `parser.zig`.)

```
<expr>        ::= <pipe_expr>
<pipe_expr>   ::= <assign_expr> ( '|>' <assign_expr> )*
<assign_expr> ::= <range_expr> ( assign_op <range_expr> )?          -- right assoc
<range_expr>  ::= <or_expr> ( '..' <or_expr> )?
<or_expr>     ::= <and_expr> ( '||' <and_expr> )*
<and_expr>    ::= <bit_or_expr> ( '&&' <bit_or_expr> )*
<bit_or_expr> ::= <bit_xor_expr> ( '|' <bit_xor_expr> )*
<bit_xor_expr>::= <bit_and_expr> ( '^' <bit_and_expr> )*
<bit_and_expr>::= <eq_expr> ( '&' <eq_expr> )*
<eq_expr>     ::= <rel_expr> ( ('=='|'!=') <rel_expr> )*
<rel_expr>    ::= <shift_expr> ( ('<'|'>'|'<='|'>=') <shift_expr> )*
<shift_expr>  ::= <term_expr> ( ('<<'|'>>') <term_expr> )*
<term_expr>   ::= <factor_expr> ( ('+'|'-') <factor_expr> )*
<factor_expr> ::= <unary_expr> ( ('*'|'/'|'%') <unary_expr> )*
<unary_expr>  ::= prefix_op <unary_expr> | <postfix_expr>
<postfix_expr>::= <primary> postfix_op*
<postfix_op>  ::= '(' <arg_list> ')' | '[' <expr> ']' | '.' <identifier> | '?'
<primary>     ::= int_literal | float_literal | string_literal | char_literal
                | 'true' | 'false' | 'null'
                | <identifier>                 -- incl. struct/enum type names & fn names
                | '(' <expr> ')'
                | '{' <stmt>* '}'              -- block expression
                | 'if' <expr> ...              -- if-expr, see §4.7
                | 'match' ...                  -- match-expr, see §4.7
                | <closure>                    -- see §4.11
                | <comptime_expr>
                | <region_expr>
                | <struct_init>
                | <fn_type_literal>            -- fn-type as first-class expr, see §4.10
```

### 4.9 Struct initializers

```
<struct_init> ::= <type_ident> ( '[' <type_args> ']' )? '{' ( '.' <identifier> '=' <expr> (',' ...)* )? '}'
```

`Type{ .field = expr, ... }`. Generic application is implicit from context in the
initializer, e.g. `Pair{ .first = 1, .second = 2.0 }` infers `Pair[i32, f64]`.
Field order is free; all fields required (no defaults).

### 4.10 Function types (first-class values) — NEW

```
<fn_type_literal> ::= 'fn' '(' <type_list> ')' '->' <type_repr>
<fn_type>         ::= <fn_type_literal>    -- as a type in <type_repr> position
                    | <fn_type_literal>    -- as an expression (a function value)
<type_list>       ::= ( <type_repr> (',' <type_repr>)* )?
```

A fn type names the full signature: parameter types and a return type.  A fn can be
referenced by name where a value of that type is expected (fn-name-as-value):

```wfr
fn add(a: i32, b: i32) -> i32 { return a + b }

fn apply(f: fn(i32, i32) -> i32, x: i32, y: i32) -> i32 {
    return f(x, y)
}

fn main() -> i32 {
    return apply(add, 2, 3)   // 5 — `add` coerces to a fn value
}
```

The `fn_type_literal` in expression position eta-expands a plain anonymous fn value;
capturing closures are always written with `|...|` (§4.11).

### 4.11 Closures — NEW

```
<closure> ::= '|' ( <closure_param> (',' <closure_param>)* )? '|' <fn_body>
<closure_param> ::= <identifier> (':' <type_repr>)?
```

- Immutable-by-default parameters (must be `mut`-declared to mutate captured state).
- Both expression bodies (`|x| x + 1`) and block bodies (`|x| { ... }`) are legal.
- Captured bindings come from the enclosing scope **by value** by default — the compiler
  composes a stack-allocated capture record (`env`) for the closure (§ `closure.env` in AST).
- A closure closes over its lexical environment via that env record.

Target (`examples/closures.wfr`):

```wfr
fn main() -> i32 {
    let base = 10
    let add_base = |x| x + base          // captures `base` by value into a stack env
    return add_base(5)                    // 15
}

fn make_adder(base: i32) -> fn(i32) -> i32 {
    return |x| x + base                    // closure with captured env, returned
}
```

Nested closures capture up through each env. `fn(...)->...` types are closure-compatible:
a closure `|x| e` coerces to `fn(T) -> U` (its env is the captured set).

### 4.12 Pipeline

```
<pipe_expr> ::= expr '|>' expr
```

`lhs |> rhs` threads `lhs` as an implicit argument into a call/closure on the rhs
(binding at precedence level 1, loosest). Canonical form:

```wfr
speak(d)      ≡  d |> speak
add(v1, v2)   ≡  v1 |> add(_, v2)     // `_` = hole filled by the piped value (target)
```

Exact `_`-hole semantics are finalized with the prelude decision; the minimum guaranteed
form is function application: `d |> speak` ≡ `speak(d)`.

### 4.13 Error propagation `?`

`postfix_expr ::= primary postfix_op*`, and `'?'` is a postfix op:

```
expr '?'    -- postfix, tightest binding (with calls/index/field)
```

`x?` unwraps `Result[T, E]`/`Option[T]` in expression position: on `Err`/`None` it
returns early from the enclosing fn (branch-to-return at codegen); on `Ok(v)`/`Some(v)`
it evaluates to `v`. Guardrail: the enclosing fn return type must be a
`Result`/`Option`.

```wfr
fn load_config() -> Result[Config, String] { ... }

fn main() -> Result[i32, String] {
    let cfg = load_config()?     // early-returns Err(String) on failure
    return Ok(cfg.port)
}
```

### 4.14 comptime

```
<comptime_expr> ::= 'comptime' <expr>
                  | 'comptime' '{' <stmt>* '}'
<comptime_call> ::= '@' <identifier> ( '(' <arg_list> ')' )?      -- builtin
<comptime_stmt> ::= <comptime_expr>                                -- statement position
```

Comptime executes code during compilation (compile-time metaprogramming).
Comptime builtins are prefixed with `@` and are usable in comptime contexts:

- `@sizeOf(T)` — byte size of a type
- `@hasField(T, "name")` — compile-time field presence test (drives generic constraints)
- `@field(x, "name")` — dynamic-name field access
- `@typeOf(x)` — type of an expression (comptime)

The exact builtin roster is finalized separately; the syntax shape above is fixed now.

### 4.15 region

```
<region_expr> ::= 'region' <identifier> (':' <type_repr>)? '{' <stmt>* '}'
```

Arena scope: `region r { ... }` allocates into the `r` arena (optionally typed by an
allocator type), freed at block exit. Memory safety and ownership follow implicit region /
value semantics.

### 4.16 move

```
move <expr>     -- unary prefix
```

Explicit move of a value into the target binding (linear/affine ownership):
`let dst = move src`.

### 4.17 Types

```
<type_repr>   ::= <named_type>
                | <ref_type>
                | <fn_type>
<named_type>  ::= <identifier> ( '[' <type_args> ']' )?      -- incl. generic app
<ref_type>    ::= '&' <named_type>                            -- shared reference
                | '&mut' <named_type>                         -- exclusive reference
<fn_type>     ::= 'fn' '(' <type_list> ')' '->' <type_repr>   -- first-class fn type
```

No lifetime annotations anywhere. References `&T` carry no lifetime
arguments; the compiler infers region lifetimes.

## 5. Removed constructs → replacements

Every removed construct maps to a functional-imperative replacement. "Removed" means
the compiler deletes the parse/lex support; such sources become parse errors.

| Removed | Old example | New form | Example |
|---|---|---|---|
| `class` decl + `prop` | `class Animal { name: String ... }` | `struct` (data only) + free fns | `struct Animal { name: String }` |
| Inheritance / override | `class Dog(Animal) { override fn ... }` | composition (`struct Dog { base: Animal ... }`) + default fns taking `&Dog` | `struct Dog { animal: Animal, breed: String }` |
| `impl Type { ... }` | `impl Person { fn speak(...) }` | free fns over the type | `fn speak(p: Person) -> String` |
| `interface` decl | `interface Speakable { fn speak(self: *Self) }` | comptime generic constraint over a fn signature | `fn greet[T](p: T) -> String` (T must supply `speak`) |
| `*impl Interface` fat pointer | `fn greet(x: &impl Speakable)` | plain fn value / closure | `fn greet(s: fn(Person) -> String)` |
| `Self` / `class_type` | `self: *Self` | explicit receiver param; no `Self` | `fn speak(v: Vec2)` |
| Method mangle `TypeName_method` | `Vec2.add` | free fn call `add(v1, v2)` | `add(v1, v2)`, `v1 |> add(v2)` |
| Dot-call dispatch | `d.speak()`, `p.swap()` | free call / pipeline | `speak(d)`, `swap(p)` |
| Associated fns | `Vec2.zero()` | free fn `zero()` | `FnObjects.zero()` / `zero()` |
| `classes.wfr` example | inheritance demo | replaced by composition + free-fn module | `structs.wfr`/`functions.wfr` style |

### 5.1 Detailed mappings

**Method → free fn with explicit receiver.** The old receiver is the first parameter;
the old call `recv.method(a, b)` becomes `method(recv, a, b)` or `recv |> method(a, b)`.

```wfr
// Before (removed)
struct Vec2 { x: f64; y: f64 }
fn add(self: &Vec2, other: &Vec2) -> Vec2 { ... }   // inline method
let v3 = v1.add(&v2)

// After
struct Vec2 { x: f64  y: f64 }
fn add(v1: Vec2, v2: Vec2) -> Vec2 { return Vec2{ .x = v1.x + v2.x, .y = v1.y + v2.y } }
let v3 = add(v1, v2)          // or: v1 |> add(v2)
```

**Interface → comptime generic constraint.** `interface Speakable` becomes a generic
`fn greet[T](p: T) -> String`; the required method set is expressed as an explicit
constraint predicate at comptime (e.g. `comptime` `@hasField`/signature check),
monomorphized per `T`.

```wfr
// Before (removed)
interface Speakable { fn speak(self: *Self) -> String }
fn greet(entity: *impl Speakable) -> String { return "says: " + entity.speak() }

// After
fn speak(p: Person) -> String { return "Hi, I'm " + p.name }
fn greet(speaker: fn(Person) -> String, p: Person) -> String { return "says: " + speaker(p) }
// dynamic flavor passes the fn value; static flavor uses comptime generics:
fn greet[T](p: T) -> String { return "says: " + speak(p) }   // speak resolved per T at comptime
```

**`self` / `Self`:** deleted. Every function's parameters are explicit; there is no
implicit receiver binding.

**`properties` (`prop name_len: i32 { get => ... }`):** replaced by free getter fns
`fn name_len(a: Animal) -> i32`. No computed-property sugar; users write accessors as
plain fns (or a pipeline: `animal |> name_len`).

**`&mut self` mutations:** mutation is explicit through `&mut` or `mut` params. A
mutating fn takes `&mut T`: `fn push(v: &mut Vec2, d: f64) { v.* = ... }`.

## 6. Prelude (surface-level)

The following builtins are in scope and are syntactically plain identifiers
(no special tokens):

- `id(x)` — identity
- `compose(f, g)` — `compose(f, g)(x) == f(g(x))`
- `curry(f)` / `uncurry` — currying and uncurrying
- `pipe(x, f)` — pipeline as a value (`pipe(x, f) == f(x)`)

These must monomorphize to direct calls / stack envs (zero-cost functional abstractions).

## 7. Conformance checklist (grammar coverage for the examples)

The grammar above is the target for every rewritten example:

| Example | Constructs exercised |
|---|---|
| `hello.wfr` | module, `fn`, call, string literal |
| `functions.wfr` | fn decl, block + `=` shorthand, no-return fn, call nesting |
| `variables.wfr` | `let`/`mut`, annotations, assignment, inference |
| `control_flow.wfr` | `if` expr, `while`, `for in a..b`, `defer`, block |
| `enums.wfr` | generic enum, variant payload `Some(T)`, `Ok(T)`/`Err(E)` |
| `match.wfr` | `match` expr, literal patterns, variant patterns, `_` wildcard, guard |
| `structs.wfr` | pure-data struct, struct init, field access, free fns |
| `generics.wfr` | generic fn `first[T]`, generic struct `Pair[A,B]`, generic enum, generic app |
| `interfaces.wfr` | rewritten: free-fn module + comptime-generic constraint demo |
| `imports.wfr` | `import a`, `import a as b`, `import a::b`, namespace use |
| `classes.wfr` | **deleted** (superseded by composition demo in `structs.wfr`/new examples) |
| `closures.wfr` (new) | `\|x\| expr`, `\|x\|\{...\}`, captures, fn values, closure→`fn(T)->U` |
| `composition.wfr` (new) | `compose`, `curry`, `id`, `pipe`, fn-type params |
| `result_errors.wfr` (new) | `Result`, `match`, `?`, `Ok`/`Err` construction |
| `pipeline.wfr` (new) | `\|>`, chained pipelines, hole `_` |

## 8. Grammar notes / edge cases

1. **Bindings**: every binding is `let name = expr` / `let name: T = expr` (immutable) or
   `mut name = expr` (mutable). There is **no** `:=` token — a bare `name = expr` at statement
   level is a plain assignment to an existing binding, so bindings always use the keyword
   prefix. A name in the `let`/`mut` slot may be `_` to discard the value.
2. **`=` roles**: `=` *introduces* a binding when it follows `let name`/`mut name` (with an
   optional `: T` in between), and *assigns* to an existing `mut` binding as an infix operator.
   The statement form is disambiguated by the keyword; the infix form is right-associative
   (level 3).
3. **Newline sensitivity**: statements end at newline or `;`; parsing continues inside
   brackets. Multi-line fn params, struct fields, and struct-init fields are legal after
   `(`, `[`, `{`.
4. **`fn` in type vs expr position**: `fn(…)` at a type position is a fn type; at an
   expression position it is a fn value/anonymous function. Disambiguation is by the
   surrounding grammar (type annotations, params, return ty, generics) exactly as the
   parser's `parseTypeRepr`/`parsePrefix` split.
5. **`_` roles**: statement discard (`let _ = f()`), wildcard pattern (`match x { _ => … }`),
   and pipeline hole `_`.
6. **`?` is strictly postfix**; it cannot be chained after a block. `f()?.g()?` is legal
   (each `?` binds to its primary).
7. **Qualified calls vs method dispatch**: `.` after a module/namespace name in call position
   (`io.print(x)`, `path.join("a","b")`) is module-qualified access — kept. `.` after a value
   is **field access only** (method-dispatch semantics are removed); `d.speak()` therefore
   stops meaning "call a method on `d`" and is parsed as field access `d.speak` followed by a
   call, which the semantic passes reject — writers use free calls (`speak(d)`) or the
   pipeline (`d |> speak`).
8. **Precedence guarantees**: pipeline is loosest (below assignment); `range` binds looser
   than assignment so `for i in 0..n` parses as a range; fn-arrow params bind loosest on the
   right of `->` so `fn(A, B) -> C` never swallows commas.
9. **No parentheses on constraint `fn` types in `|...|` closures** — closure params are never
   parenthesized; the closure delimiter `|` is the opening token.

## 9. Relationship to implementation

- Token set (§2) requires dropping `impl_kw`/`interface_kw`.
- AST shapes (struct fields-only, `fn_decl` generic+params+return+body, closures with
  `env`, `comptime_call`, `pipeline`, `try_propagate`, no `impl_type`) nest the grammar above.
- Every `<decl>`/`<stmt>`/`<expr>` rule here corresponds one-to-one to a parser routine;
  OOP rules (`parseInterfaceDecl`, `parseImplBlock`, struct `methods`) are deleted.