# Wolframite Semantics Specification

The **runtime and type semantics** for the functional-imperative rewrite. This document
is the law for the semantic passes (name resolution, type checking, monomorphization)
and for how the frontend lowers fn values, closures, and generic instances to the
Tungsten IR. It is grounded in `design.md` (philosophy, memory model, anti-goals) and
`docs/syntax.md` (surface grammar). Grammar lives in `docs/syntax.md`; this document
answers *what programs mean* and *how they compile*.

Numbered rules (`R1`, `R2`, …) are normative: an implementation passes if it satisfies
every rule. Each section maps to the compiler layer that owns it.

---

## 1. Terms and target

| Term | Meaning |
|---|---|
| **value** | A runtime value of a first-class type, carried in a stack slot (`alloca`), register, or aggregate field. |
| **fn value** | A first-class function: a pair `(fn_ptr, env_ptr)` (§4). |
| **env / env record** | The captured-by-value storage of a closure (§5). |
| **instance** | The concrete, monomorphized copy of a generic definition for one type-argument list (§7). |
| **slot** | The backend's 8-byte stack cell used by the codegen for a value. |

Implementation targets, per layer:

| Layer | Owns |
|---|---|
| `compiler/semantic/types.zig` | `SemType` union incl. the `function` member and generic `app` representation, `TypePool` |
| `compiler/semantic/scope.zig` | `SymbolKind` (no `class_type`/`interface_type`), fn-name-as-value symbols |
| `compiler/semantic/resolve.zig` | capture-env inference, generic instance registration, fn-value resolution |
| `compiler/semantic/typecheck.zig` | typing rules R4–R38, `?` rules R26–R29, constraint eval ordering |
| `libs/backend/src/ir.zig` + `api.zig` | `function_value` IR type, env-placed direct calls, call-through-ptr with env |
| `compiler/codegen/lower.zig` | closure lifting + env record construction, hidden-env-param ABI, `?` branch-to-return, monomorphized function emission |

## 2. Execution & memory model (unchanged)

The memory model of the rewrite is the memory model of today, restated for clarity:

- **M1. No garbage collector, no tracing, no finalizers.** All deallocation is
  deterministic and static.
- **M2. RAII drives destruction.** A value drops exactly when it leaves scope:
  at block exit, at `defer` execution, and at function return. Drop order is reverse
  declaration order; `defer` runs last-in-first-out after the block's other drops.
- **M3. Region-based allocation.** `region name { ... }` (§4.15 of `docs/syntax.md`)
  creates an arena freed at block exit. Allocations go through the region's allocator.
  Regions may nest; an inner region is freed before its enclosing region.
- **M4. Value semantics.** Bindings and parameters are immutable unless `mut`. Passing a
  value to a fn, `let dst = move src`, and closure capture copy or move the value; there
  is no hidden aliasing or hidden `this`.
- **M5. No vtables, no class layout, no hidden pointer.** There is no
  `[vtable_ptr][ref_count][...]` class preamble anywhere. Structs are plain aggregates
  (§3).
- **M6. Explicit allocation control.** Any heap/arena allocation is visible in source
  (`region`, explicit allocator params) or is a documented compiler rule (escaping
  closure envs, §5.4).

`design.md` §1–§3 are the philosophical backing for M1–M6 and are not changed by this
rewrite.

## 3. Data layout semantics

### 3.1 Structs are plain aggregates — R1

A `struct` is a bundle of fields, packed in **declaration order**, each field aligned to
its natural alignment; the struct's alignment is the maximum of its field alignments and
its size is the smallest multiple of that alignment that fits all fields (x86-64 layout
rules). No vtable pointer, no reference count, no hidden fields. Consequence for the
lowerer: struct field access is a static byte offset exactly as the current
`structFieldOffset` already computes — only the `class_*` preamble variants are removed.

### 3.2 Enums are tagged unions — R2

`enum E { V0(T0…) V1 … }` lowers to an **inline tag + inline payload** record
(no indirection):

```
offset 0                    tag (u8, or u16/u32 if > 256 variants — see below)
offset align(payload)        payload union sized to the largest variant
```

- The tag is the variant index (`0..n-1`) in declaration order.
- The payload is the flat union of variant payload tuples, laid out with the same
  alignment rules as structs; a zero-field variant (`None`) contributes nothing.
- Tag width is `u8` when `n <= 256`, else the smallest `{u8,u16,u32}` that holds `n-1`.
- R2a. An instance of a generic enum (`Option[i32]`, `Result[String, i32]`) has the same
  layout rule with the substituted payload types.
- R2b. `@sizeOf(E)` returns the record size; `@field`/pattern access on a payload goes
  through the payload union offset. Match lowering compares the tag (§8).

This matches the current `enumPayloadOffset`/`enumSizeFor` helpers; the rewrite keeps them
unchanged.

### 3.3 The fn value record — R3

A **fn value** is a 16-byte record in the codegen slot model:

```
offset 0    fn_ptr   (u64 — address of the lifted callee)
offset 8    env_ptr  (u64 — address of the capture record, or 0)
```

- `@sizeOf(fn(...) -> R)` is 16; alignment is 8.
- **R3a.** A fn value with no captures carries `env_ptr = 0` (null) and still obeys the
  uniform calling convention (§6.2) — the callee simply ignores its env slot.
- **R3b.** There is no third word and no method/type table. Equal fn values are equal on
  both words: `f1 == f2` iff `f1.fn_ptr == f2.fn_ptr and f1.env_ptr == f2.env_ptr`.
  Fn values are not ordered and are not matchable patterns.

The IR represents this as a dedicated type (§6.4). The key consequence: a fn value can be
stored in a struct field, an array, a region, or another closure's env — it is just a
16-byte aggregate.

## 4. Functions and function values

### 4.1 The semantic fn type — R4

The semantic type of a function is described by the `function` member of `SemType`
(already present):

```
function_type := { param_types: []TypeIdx, return_type: TypeIdx }
```

`fn(A, B) -> R` in `docs/syntax.md` §4.10 compiles to exactly this shape. Two fn types are
equal iff param lists and return types are pairwise equal (structural equality, as the
current `semTypesEqual` already implements).

**R4a.** The *captured set* of a closure is **not** part of its `function_type`. Two
closures with the same visible signature are the same type even when they capture
different variables. The env schema is per-closure-instance lowering metadata (§5.2),
never part of the type identity.

**R4b.** `fn_type_literal` in **type position** (`x: fn(i32) -> i32`, `Vec[fn(i32)->i32]`,
return annotations) denotes the `function_type`. In **expression position** it denotes the
same fn type value at comptime (a type constant usable in `@typeOf`, generic argument
lists, and annotations); it is **not** a constructible runtime function. Opaque uses in
runtime expression position are a type error ("fn type literal is a type, not a value;
use a closure or a fn name").

### 4.2 Fn-name-as-value — R5

A top-level `fn` symbol used in value position coerces to a fn value of its signature
type: `apply(add, 2, 3)` passes `add` as a `fn(i32, i32) -> i32` value (§4.10 of
`docs/syntax.md`). Rules:

- **R5a.** Any non-generic `fn` may be referenced as a value; the reference has type
  `function_type` built from its declared params and return type.
- **R5b.** A *generic* fn name may only be referenced as a value **after** instantiation
  (`curry(first[i32])`); a bare generic fn name in value position is an error ("generic
  fn requires type arguments"). (Instantiation: §7.)
- **R5c.** `main` may not be referenced as a value (§6.3).

### 4.3 Name resolution consequences — R6

The resolver keeps `function` symbols in value scope (a `fn` name resolves like a
comptime-bound value whose type is its signature). This requires removing the
`class_type`/`interface_type` symbol kinds and `Self` handling from `scope.zig`
(`SymbolKind` becomes: `local`, `param`, `function`, `struct_type`, `enum_type`,
`generic_param`, `module`).

- **R6a.** There is no overloading: at most one `fn` per name per module. Generic
  specialization (different concrete bodies for different `T`) is expressed by
  comptime branching inside one generic fn (§7.5), never by duplicate names.
- **R6b.** A `fn` name and a `struct`/`enum` name share the module namespace; the
  resolver rejects redefinition as today.

## 5. Closures

### 5.1 Capture set inference — R7

For a closure literal `|p1, ..., pn| body`:

- **R7a.** The **capture set** is the set of identifiers used free in `body` (not bound by
  the closure's own params, an inner block, a nested closure's params, a `let`, a
  match-arm pattern, or loop variables).
- **R7b.** Capture order is **source order of first appearance** in `body`, with each
  captured name appearing once (dedup). This fixes the env record layout deterministically
  (R8), which keeps IR output and tests stable.
- **R7c.** Free identifiers that are module-level functions, struct/enum type names, or
  enum variants are **not** captured (they resolve to static entities).
- **R7d.** Free names resolved to `generic_param` (`T`) are captured like values — the
  capture type is the substituted concrete type after monomorphization (§7.5).

### 5.2 Env record — R8

The capture set `{c0, c1, ..., ck}` compiles to a record type private to the lowering:

```
env_type := struct { c0: T0,   // types from the environment at the literal's site
                     c1: T1,
                     ...
                     ck: Tk }
```

- **R8a.** Layout obeys R1 (declaration order, natural alignment).
- **R8b.** A closure with empty capture set compiles with a zero-size/none env; its
  fn value carries `env_ptr = 0` (R3a).
- **R8c.** Captures are **by value at creation**: the record is materialized (copied)
  when the closure literal evaluates. The closure owns its copies (RAII drops them,
  §5.6).
- **R8d.** A captured `mut` binding is copied by value too; the copy inside the env is
  mutable **when and only when** the closure body assigns to it (the compiler analyzes
  the body for assignment before deciding the field's mutability). A by-value copy means
  closure-local mutation never aliases the outer binding; there is **no shared-reference
  capture** in this design, and no hidden mutable state leaks outward.

### 5.3 Nested closures — R9

A closure inside a closure captures, by value, whatever its own body uses free —
including params and captures of the enclosing closure, which are ordinary values:

```
let outer = |x| { let inner = |y| x + y; return inner }   // inner env: { x }
```

- **R9a.** Because every capture is a by-value copy, an inner closure never needs a
  pointer chain into an outer env. Its env is self-contained (§6.1).
- **R9b.** Capturing a closure value (a `let f = |...|...; |x| f(x)`) captures the whole
  fn-value record (fn_ptr + env_ptr) by value (R3).

### 5.4 Env placement and the escape rule — R10

An env record must live somewhere addressable. Placement is decided once, at lowering,
by a **flow-based escape check** over the closure literal:

| Case | Placement |
|---|---|
| Closure value provably does **not** outlive the creating frame (called locally, passed **downward** to a callee that cannot store it, stored into data that stays inside the frame) | **Stack slot** (`buildAlloca`) in the creating frame — the fast, default path |
| Closure value is returned, stored into a struct that escapes upward, or stored into region-allocated/heap data | **Raising** to the innermost enclosing `region` arena if one exists; otherwise a heap allocation from the default allocator with an RAII drop |

- **R10a.** *Stack default.* The stack path is created by default; the escape check only
  raises the env when it finds an escape.
- **R10b.** *Escape detection.* A closure result (or a struct/aggregate containing one)
  is escaping when it is: (1) the value of a `return`; (2) assigned into a binding that
  outlives the creating frame (module-level bindings: the env is a static/global record);
  (3) stored through a pointer whose pointee is not frame-local (region/heap); (4) passed
  to a callee whose parameter storage is unknown — the conservative default is *escape*,
  but monomorphized callees are analyzed precisely (§7) rather than assumed.
- **R10c.** *Module-level closures.* A closure literal in module scope has its env in a
  module-global record (one per literal); module bindings referenced by it are globals.
  The closure never dangles.
- **R10d.** *Cost.* All non-escaping closures cost one `alloca` plus per-capture copies —
  the zero-cost stack path of `design.md` §2. Escaping envs allocate exactly once at the
  literal's site and are freed by the region or by the RAII drop that owns them.

### 5.5 Closure typing — R11

A closure `|p1: A, ..., pn: B| body` with captured set `{c0..ck}` has:

```
function_type { param_types = [A..B], return_type = typeof(body) }
env schema       = [c0..ck]             (lowering metadata, not type identity)
```

- **R11a.** If a closure's param at a *use* site is expected as `fn(p1: A, ..., pn: B) -> R`,
  the closure must have the same param count and pairwise-unifiable param types, and its
  body type must unify with `R`. This is the closure→`fn(...)` coercion from
  `docs/syntax.md` §4.11: it is an ordinary assignment, not a cast.
- **R11b.** A closure with inferred params (`|x| x + 1`) is typed against the expected
  `function_type` when the context fixes it (let annotation, param type, return type).
  Without an expected type, the param types are inferred from the body ("unification
  only", §7.6). Without an expected type and with an ununifiable body, the closure is an
  error ("cannot infer parameter type of closure"); it never defaults.
- **R11c.** Closure bodies are typed exactly like fn bodies: same `?` rules
  (§8), same immutable-by-default params (`mut`-declared params may mutate).

### 5.6 Env lifecycle — R12

- **R12a.** The env record and its captured copies drop at the scope exit of the site
  that created them (RAII, M2), for stack envs.
- **R12b.** Region-raised envs are freed by the region's block exit (M3).
- **R12c.** Heap-raised envs drop via a hidden drop call on the creating frame's scope
  exit (the compiler emits the drop; the user writes no destructor). If the closure can
  still be alive after that (e.g. captured into a region whose lifetime it escapes),
  the compiler rejects the program ("closure env outlives its region") rather than
  emitting dangling code. Escaping closures are therefore region-bounded: a returned
  closure's env lives in a region that outlives the caller.
- **R12d.** `defer` in the creating scope runs after the env's drop, matching M2.

## 6. Calling convention and IR lowering

### 6.1 Lifting — R13

Every closure literal lowers to:

1. a private **lifted fn** — a module-level function whose body is the closure body with
   every free captured name replaced by `env.field` accesses;
2. an **env construction** at the literal's site — the by-value record built and placed
   per R10;
3. a **fn value** — the pair `(lifted_fn, env_ptr)` stored in the result slot.

Name of the lifted fn: `__closure_{fn}_{n}` inside the lowering namespace (`fn` = the
enclosing function's name, `n` = monotonic per-module counter). Names are internal and
never user-resolvable (R6 namespace rules still allow any identifier with `__`
prefix — the mangling rules in §7.4 reserve `__` for the compiler).

### 6.2 Uniform hidden-env-parameter ABI — R14

Every function lowered by the Wolframite frontend — declared `fn`, lifted closure, and
compiler-generated prelude/instance functions — has a **leading hidden env parameter**:

```
fn f(env: &Env_f, p0: T0, ..., pn: Tn) -> R
```

- **R14a.** At a **direct named call** `f(a0, ..., an)`, the env argument is `null`
  (`buildCall` with a null env constant as the first operand). Non-capturing functions
  never read it. Captured access in a lifted closure reads `env` (its first param)
  through static offsets.
- **R14b.** At an **fn-value call** `fval(args)`, the env argument is `fval.env_ptr`
  (§3.3, §6.4). Because *all* callees have the env-first hole, the callee's own code knows its
  env layout; the caller never needs it. This is what makes `fn(T)->U` safe as a
  first-class type without type erasure or a vtable: the env pointer is opaque at call
  sites (it is just argument 0) and meaningful only inside the lifted callee.
- **R14c.** Call sites and callees are always in the same module and same toolchain, so
  this is an internal ABI; nothing else observes it.

**Consequence (no thunks).** A plain `fn` referenced as a value uses its own address as
`fn_ptr`; there is no wrapper function and no thunk. A non-capturing closure's lifted fn
takes an env it never reads. Method A — uniform env-first — is selected over
per-value wrappers because it removes thunk machinery entirely and makes direct calls cost
a single null-env operand.

### 6.3 `main` — R15

`fn main()` is exempt from R14: it is emitted with no hidden env param and standard
`main(argc, argv)` entry semantics. Direct calls to `main` from within the program pass
a null env (the callee ignores it); referencing `main` as a value is an error (R5c).

### 6.4 IR types and ops — R16

The backend gains the value model needed by §3.3/§6.2:

- **R16a.** New IR type `function_value` in the `IrType` union (alongside the existing
  `int/float/pointer/function`): a 16-byte `{ fn_ptr: ptr, env_ptr: ptr }` record with
  natural alignment 8.
- **R16b.** New builder `buildFnValue(ret_type, fn_ptr: Value, env_ptr: Value) -> Value`
  that materializes the record into a slot (allocate 16 bytes, `store` both words).
- **R16c.** `call_ptr` (already present in `ir.zig`/`codegen.zig`) is re-specified: its
  callee operand is a value of type `function_value`; codegen loads `fn_ptr` from slot+0,
  loads `env_ptr` from slot+8, **passes env_ptr as argument 0**, then `call rn` with the
  visible args shifted by one slot. (Today `call_ptr` treats `ops[0]` as a bare address;
  the rewrite changes it to the pair.)
- **R16d.** Loads/stores/blocks handle `function_value` as a 16-byte aggregate; a fn
  value inside a struct field or env record is just bytes at a static offset.
- **R16e.** The fn-value **fast path**: when a call goes through a fn value whose
  `fn_ptr` is statically known (monomorphized prelude, `compose` of known fns, closure
  lifts), the lowerer emits a direct `buildCall` to that target with the known env —
  no `call_ptr` at all (§7.5, §9). This is the "direct function calls" zero-cost target
  of `design.md` §2.

### 6.5 Direct-call cleanup — R17

With R14, the lowerer's call emission is uniform:

- named fn → `buildCall(f, [null_env, args...])`
- fn value → `call_ptr` with env as hidden arg 0 (or the R16e fast path)
- lifted closure (direct, monomorphization-known) → `buildCall(lifted, [env, args...])`
- `extern`/C functions → `buildExternCall` unchanged (no env slot; C ABI)
- vtable/`fn_array` globals and `lowerIfaceMethodCall` are deleted; `GlobalKind.fn_array`
  is removed from the backend global model (R18).

**R18.** No `fn_array` globals, no vtable globals, no `GlobalKind.fn_array`,
no class preamble, after this rewrite. The only global data is string literals and
module-level closure envs (R10c) and monomorphized static records.

## 7. Comptime generics and monomorphization

### 7.1 The generic model — R19

- **R19a.** Generics are **comptime-only**. All polymorphism is resolved by the compiler;
  no runtime type information exists. Generic defs (fn, struct, enum) are templates.
- **R19b.** A generic param `T` has **no bounds** declared in type position (no
  `T: Bound` syntax; `docs/syntax.md` §5 maps `interface` to comptime predicates).
  Constraints are *checked by comptime code inside the body* (§7.5).
- **R19c.** A generic application is `Name[Arg0, ..., Argk]` in type position
  (`Option[i32]`, `Pair[i32, f64]`, `Vec[fn(i32) -> i32]`) with **all** args supplied;
  there are no default type args and no partial application at comptime (composing
  `curry`/`compose` on *values* gives function-level partial application; type-level
  partial application is out of scope).
- **R19d.** Generic params have the existing `generic_param` semantic type; every use of
  `T` in a generic fn or struct is a `generic_param` TypeIdx that substitution rewrites
  per instance.

### 7.2 Instance identity — R20

For a generic declaration `D[P0..Pk]` and concrete args `A0..Ak`:

- An **instance** is `(decl_node, [A0..Ak])`.
- **R20a.** Instance identity is by **def-eq** of the arg types (structural equality as in
  §4.1): two syntactically different sites naming the same `struct`/`enum` instance are
  one type.
- **R20b.** The type layer adds a memoized **application cache**: `map<(decl_node, arg
  hash) -> TypeIdx>` so `Option[i32]` used a hundred times creates one `enum_type`
  TypeIdx. The cache is the only place instance types are created.
- **R20c.** Generic structs/enums instantiate to the same plain aggregate/tagged-union
  layouts as §3 with substituted field/variant types.

### 7.3 Instantiation rules — R21

The compiler maintains a **generic table** (per module) of generic decls, and an
**instantiation cache** keyed by `(decl_node, concrete args)` holding the monomorphized
instance symbol. Instantiation is **lazy and driven by use**:

1. A use site that resolves to a generic fn/struct/enum registers a **pending
   instantiation** on first encounter and checks the cache first.
2. **Substitution.** The compiler builds `{P_i → A_i}`, *clones* the decl body, and
   rewrites every `generic_param` occurrence (in type positions, expressions, and nested
   `Name[T]` applications) to the concrete `A_i`. Name resolution and type checking then
   run **on the clone** in a fresh scope, exactly like ordinary code.
3. **Constraint evaluation and specialization** run during step 2's type checking
   (§7.5).
4. The finished instance is added to the cache and lowered (fn instances emit a
   mangled function; struct/enum instances emit a TypeIdx only).
- **R21a.** *Recursion is safe.* If the body of `D[A0..Ak]` uses `D[B0..Bk]`, that use
  looks up the cache; a cycle resolves to the instance already being built (self-recursion
  through the cache, not infinite cloning). Structural recursion (`List[int64]` whose
  body contains `List[int64]`) terminates because the cache key is a finite type tuple.
- **R21b.** *Blow-up guard.* Identical `(decl_node, args)` keys always map to the one
  cached instance (R20b/R21 step 4). There is no exponential re-instantiation.

### 7.4 Name mangling for instances — R22

Instance function names are compiler-internal and deterministic:

```
<base>__<mangled args...>
```

| Arg type | Mangle |
|---|---|
| `i8..i64`, `u8..u64`, `f32`, `f64` | the spelled name, e.g. `i32`, `f64` |
| `bool` | `b` |
| `String` | `str` |
| pointer `*T` | `pt_<T>`; `*mut T` `pm_<T>` |
| fn type | `fn_<ret>__<arg1>_<arg2>...` |
| struct/enum instance | `<name>_<mangled args>` |
| closure type (only inside instances) | `cl_<n>` |

Examples: `first[i32]` → `first__i32`; `Pair[i32, f64]` → fields of type instantiate
with `Pair__i32_f64`; `map[fn(i32) -> i32]` → `map__fn_i32__i32`. Instance *identity*
never depends on the label — the type-arg-keyed cache (§7.2) is authoritative — so the
mangled string only needs to be stable and unique enough for assembly output. All
instances live in the compiler's internal namespace; users never write them.

### 7.5 Constraints and specialization — R23

A generic param is constrained **by the comptime code that mentions it**.

- **R23a.** Comptime builtins evaluate to comptime values once their args are concrete:
  - `@typeOf(x)` — the type of `x`;
  - `@sizeOf(T)` — `u64` byte size of `T` per §3;
  - `@hasField(T, "name")` — `bool`: true iff `T` is a non-generic-or-instantiated
    struct with that field;
  - `@field(x, "name")` — dynamic-access field value (comptime when `x` is comptime).
  (The roster beyond these four is finalized separately; the semantics of the four above
  are fixed by this document.)
- **R23b.** During instantiation, a `comptime` expression containing substituted `T`
  is evaluated; a **false** expected condition (e.g. a `comptime if` guard that must
  hold, an explicit `comptime { assert(...) }`) produces a compile error naming the
  constraint: "generic constraint not satisfied: T = i32 does not satisfy
  @hasField(T, \"name\")". Type checking of the instantiated clone then stops at that
  use.
- **R23c.** **Specialization** is `comptime if` over substituted types inside the generic
  body: `comptime if @hasField(T, "len") { ... } else { ... }` picks one branch per `T`.
  Both branches type-check after substitution (they are real clone code); dead
  comptime branches are pruned at lowering.
- **R23d.** The `interface Speakable → comptime-generic constraint` mapping of
  `docs/syntax.md` §5 is realized *only* through R23 (there is no `satisfiesInterface`
  machinery left): a generic `fn greet[T](p: T) -> String` constrains `T` by
  `comptime @hasField(T, ...)` tests or by calling free `speak(...)` whose resolution is
  attempted after substitution. Because overloading is absent (R6a), per-`T`
  dispatch is written as comptime branching, not as multiple `speak` definitions.

### 7.6 Type-argument inference — R24

At a generic **call** `f(args)` with generic fn `f[P0..Pk](...)`:

- **R24a.** Each `P_i` that occurs in a parameter type is unified **from the
  corresponding argument type** (one-directional: argument → parameter). Equal
  occurrences unify to one type; conflicts are an error.
- **R24b.** A `P_i` that occurs *only* in the return type is **not** inferable and must be
  spelled: `empty[i32]()`. Inference never looks at the expected result type (no
  bidirectional inference).
- **R24c.** Inference produces concrete types only; it never leaves a pending `P_i` open.

### 7.7 Generic structs and enums — R25

`struct Pair[A, B] { first: A, second: B }` and `enum Option[T] { Some(T) None }`
instantiate per R20–R21: a use site `Pair[i32, f64]{ .first = 1, .second = 2.0 }`
(§4.9 of `docs/syntax.md`) applies the instance and types fields after substitution.
Struct init may omit `[args]` when they are recoverable from the field values and the
field types mention exactly the generic params (one-way unification, R24). All fields
remain required.

## 8. Error propagation `?`

### 8.1 What `?` applies to — R26

`x?` (`docs/syntax.md` §4.13) is legal when the type of `x` is an instantiated enum with
**exactly two variants** where one variant has exactly one payload field:

- the single-payload variant is the **success** variant; its payload type `T` is the type
  of `x?`;
- the other variant is the **error** variant; its payload is 0 or 1 fields, and when 1
  field, that payload type `E` is the *error type*.

`Result[T, E]` (`Ok(T)`/`Err(E)`) and `Option[T]` (`Some(T)`/`None`) satisfy this by
shape; any other two-variant enum with the same shape also supports `?` (there is no
hard-coded `Result`/`Option` — shape decides). A three-or-more variant enum or a
two-variant enum with payloads on both variants is rejected with
"`?` needs a one-payload success variant and an error variant".

### 8.2 Type rules — R27

`x?` in a function (or closure) body with enclosing return type `R`:

- **R27a.** Let `D` be the enum declaration of `x`'s type, `T` its success payload, `E`
  its error payload. The enclosing return type `R` must also be an instance of the **same
  enum declaration `D`** (`R = D[...]`). `?` in a `void` or non-`D`-returning fn is an
  error ("`?` requires the enclosing function to return the same Result/Option type").
  There is **no cross-enum and no `From`-style coercion** in the base rule; mismatched
  error payloads are user-checked at the point where the propagated value is used.
- **R27b.** When `R = D[T', E']`:
  - `x?` evaluates to the success payload of type `T`.
  - on the error variant it evaluates to `return` of `D[T', E']` constructed from the
    *error* payload; the error payload type of the operand and of `R` must be equal
    (`E == E'`) for the return expression to type-check — otherwise the construction
    errors at this point (the `Ok`/`Some` payloads `T`/`T'` are not involved).
- **R27c.** For `Option` (zero-field error variant), `x?` propagates the `None` variant
  of `R`; no payload equality is required.
- **R27d.** `?` has postfix / tightest binding (§4.8 of `docs/syntax.md`): `f()?.g()?`
  parses left-to-right; each `?` applies to its own primary.

### 8.3 Lowering — R28

`x?` lowers to a **branch-to-return** (no helper, no exception runtime):

```
t = load tag of x
cond_br t == err_tag, bb_propagate, bb_ok

bb_propagate:                          // early return path
    if error variant has payload: p = load error payload of x
    e = construct R.err(p)             // enum constructor with R's substituted types
    ret e                              // (or ret R.none for Option)
bb_ok:
    v = load success payload of x      // value of the `?` expression, joined by phi
```

- **R28a.** The success value flows onward without a call; the propagate path is a
  single conditional branch plus a `ret`. This is the "compiles to a branch-to-return"
  requirement.
- **R28b.** Match exhaustiveness is unchanged: `?` is desugared into the implicit
  two-arm match above, so it cannot make a `match` non-exhaustive and a direct
  `match x { Ok(v) => ..., Err(e) => return ... }` keeps its today's exhaustiveness
  checking. No exhaustiveness logic changes; `?` just gets the same treatment as a
  two-arm match.

### 8.4 Contexts — R29

- **R29a.** `?` is legal in fn bodies and closure bodies. Inside a closure, the
  "enclosing function" of R27 is the closure itself and its *inferred* return type must
  satisfy the rule (a closure whose body has `?` must return the two-variant enum).
- **R29b.** `?` in a `void` closure/fn is rejected at type time.
- **R29c.** `?` in comptime context is rejected (there is no success/error at comptime;
  use `comptime` conditionals instead).

## 9. Pipeline and the composition prelude

### 9.1 Pipeline `|>` semantics — R30

`lhs |> rhs` (`docs/syntax.md` §4.12) is a **pure desugaring**, evaluated at the AST
level before lowering:

- **R30a.** If `rhs` is a call with a **hole** — exactly one argument that is the
  identifier `_` — the piped value replaces the hole:
  `lhs |> add(_, b)` ≡ `add(lhs, b)`.
- **R30b.** Otherwise, if `rhs` is a call, the piped value is prepended as argument 0:
  `lhs |> add(b, c)` ≡ `add(lhs, b, c)`.
- **R30c.** If `rhs` is a bare fn name (or any closure-free primary destructuring to a
  function value), `lhs |> speak` ≡ `speak(lhs)` (function application).
- **R30d.** More than one `_` in a piped call is an error. A `_` in a call that is *not*
  part of a pipeline is an error ("`_` hole outside a pipeline").
- **R30e.** Pipelines are left-associative at the loosest precedence; chained pipes
  desugar inside-out: `v |> f |> g` ≡ `g(f(v))`.
- **R30f.** Type rule: the piped value's type must unify with the hole position (or param
  0) of the callee; the pipeline's type is the callee's return type (R24-style
  one-way unification applies, including generic instantiation through the pipe).

### 9.2 Composition prelude — R31

The prelude functions `id`, `compose`, `curry`, `uncurry`, `pipe` (`docs/syntax.md` §6)
have source-expansion semantics: each is equivalent to an explicit closure, so each
compiles through the exact closure machinery of §5–§6 (stack envs, hidden-env ABI,
R16e direct-call fast path when operands are statically known):

| Prelude call | Equivalent (source expansion) |
|---|---|
| `id(x)` | `x` |
| `pipe(x, f)` | `f(x)` |
| `compose(f, g)` | `\|x\| f(g(x))` — a closure capturing `f`, `g` by value |
| `curry(f)` | `\|a\| \|b\| f(a, b)` (2-ary; generalized to `n` by nesting) |
| `uncurry(h)` | `\|a, b\| h(a)(b)` (2-ary; generalized similarly) |

- **R31a.** `compose(f, g).type = fn(A) -> C` when `g: fn(A) -> B` and `f: fn(B) -> C`;
  the captured-env types come from the operands (§4.2/R5 value typing, R11 closure
  typing).
- **R31b.** When `f`/`g` are statically known fn names (or lifted closures the compiler
  can see), the expansion's inner calls lower directly (`buildCall`) — `curry(add)(1)(2)`
  emits two direct calls with stack envs, no `call_ptr`, satisfying the "monomorphized to
  direct calls" requirement. Dynamic operands use fn-value `call_ptr` (§6.4).
- **R31c.** `compose`/`curry` have no runtime identity: a `compose` expression is *not* a
  boxed heap object; it is the closure (16-byte fn value + env record).

## 10. Interaction rules

- **R32 (fn values as data).** A fn value may appear in a struct field, array, slice,
  or env record; copying such aggregates copies the pair (§3.3). Equality is
  single-`==` on both words; storing a fn value never moves the underlying env — it
  copies the reference. The env's lifetime is that of the record that created it (§5.6);
  a copied fn value and its creator share one env.
- **R33 (closures over closures).** R9/R32 compose: nested and captured closures are
  ordinary 16-byte values in envs; escaping follows R10 through the innermost enclosing
  region.
- **R34 (`?` and pipes).** `f()?.g()?` and `v |> f?` are ordinary combinations of R30
  and R26; pipelines desugar first, then `?` applies to the desugared primary.
- **R35 (defer + envs).** Env drops are plain RAII locals (R12); defer ordering is
  unchanged (M2).
- **R36 (comptime + generics).** Generic fn/struct instances are comptime products:
  no RTTI, no runtime generics, instance mangling (§7.4) only. Comptime builtins operate
  on substituted types (§7.5).
- **R37 (imports).** Instances are per-module; the generic table belongs to the module
  that declares the generic (§7.3). Imported generic decls instantiate in the importing
  module's table cache under the same `(decl_node, args)` key (imports resolve to the
  same decl node, so the cache is naturally shared).
- **R38 (diagnostics).** All error messages use the free-fn model: no "method",
  "interface", "class", "Self", "vtable" wording anywhere (§5.2 of `docs/syntax.md`).

## 11. Conformance checklist

Each `docs/syntax.md` surface construct and its binding rule:

| Construct | Rule(s) |
|---|---|
| `fn(A, B) -> R` type + value typing | R4, R4b |
| fn-name-as-value | R5, R6 |
| closure `\|x\| e` / `\|x\| {...}` | R7, R8, R11, R13 |
| closure captures by value into stack env | R8, R10, R12 |
| closure→`fn(T)->U` coercion | R11a |
| nested closures / closure-in-closure | R9, R33 |
| first-class fn values (call-through-ptr) | R3, R6, R14, R16 |
| `compose`/`curry`/`id`/`pipe` zero-cost | R31 |
| `\|>` pipe + hole | R30 |
| `?` on `Result`/`Option` | R26–R29 |
| `match` exhaustiveness with `?` | R28b |
| comptime generics `first[T]` | R19–R25 |
| `@hasField`/`@sizeOf`/`@field`/`@typeOf` constraints | R23 |
| structs as pure data, aggregates | R1, R17, R18 |
| enum sum types | R2 |
| region / implicit memory model | M1–M6, R10, R12 |
| no `impl`/`interface`/`Self`/vtable | R6, R17, R18, R38 |

A semantic pass or lowering change is complete when:
1. every rule in the sections that layer owns is implemented and mirrored by a test
   (compiler tests for R4–R29; backend tests for R3/R16; lowerer tests for R13–R18,
   R28, R31); and
2. `examples/closures.wfr`, `composition.wfr`, `result_errors.wfr`, `pipeline.wfr`,
   and the generic examples all type-check and lower to IR with **zero**
   vtable/`fn_array`/hidden-`this` artifacts.