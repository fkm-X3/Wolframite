# ADR: Runtime archive `wfr_std` — lookup and linking strategy

## Status

Accepted

## Date

31-10-2026

## Context

Tungsten now emits relocatable object files (ELF64 on Linux, PE/COFF on
Windows) and Ferro links them into a runnable executable. Every program links
against the Wolframite runtime `wfr_std` (built by `zig build` from
`libs/std`), which provides the `wfr_std_*` symbols prelude calls lower to
(e.g. `wfr_std_print`). This ADR decides how Ferro finds `wfr_std` and how it
is linked: as an object/archive Ferro reads directly, or as a pre-linked
object.

## Scope

- Runtime archive: `wfr_std` (static archive built by `zig build`, installed to
  `zig-out/lib`).
- Platforms: Linux (ELF) and Windows (PE/COFF), x86_64 only.
- Who resolves the path: the caller of `linkObject` (ore, or Wolframite code
  driving the linker directly); `linkObject` itself takes `runtime_lib` as an
  explicit path argument.

## Decision

### 1. Keep linking `wfr_std` (unchanged)

`libs/std` continues to be built by `zig build` as a static library archive
(`b.addLibrary(.{ .name = "wfr_std", .linkage = .static, ... })`) and installed
to `zig-out/lib`. No change to `build.zig`.

### 2. Archive strategy: Ferro reads `wfr_std` directly

`wfr_std` is shipped as a **static archive that Ferro reads directly**, not as
a pre-linked object.

- Not pre-linked: pre-linking would require a linker to already exist
  (chicken-and-egg) and would bake addresses into the runtime, conflicting
  with Ferro's relocation application.
- Ferro's object reader reads the archive container for the target platform —
  ELF `ar` (`.a`) on Linux, COFF library (`.lib`) on Windows — and extracts
  the member objects whose symbols satisfy the program's undefined references.
  A single-object file is also accepted.
- This matches the link stages (`readObject(object_path)` +
  `readObject(runtime_lib)`) and the `linkObject` signature, which takes
  `runtime_lib` as a path Ferro reads directly.

### 3. Lookup strategy: same install layout as today's `findWfrStdLib`

`linkObject` never guesses where `wfr_std` lives — `runtime_lib` is passed in
by the caller. The caller (ore) resolves the archive name to a path using the
same layout as today's `findWfrStdLib` (`src/ore/link.zig`), tried in order:

1. `zig-out/lib/<name>` — project-local `zig build` install.
2. `build/zig-out/lib/<name>` — in-tree alternative layout.
3. `<exedir>/../lib/<name>` — install layout (mirrors `zig-out/`; `<install>/bin/ore`
   alongside `<install>/lib/wfr_std(.lib|.a)`).
4. `/usr/local/wolframite/lib/<name>` — POSIX system install.

Archive names, matched per platform:
- Windows: `wfr_std.lib` (primary)
- Linux: `libwfr_std.a` (primary), `wfr_std.a` (fallback)

The link description's `runtime_lib` field (authored in Wolframite, e.g.
`let runtime_lib = "wfr_std.lib"`) supplies the archive *name*. ore resolves
that name against the lookup dirs above and passes the resolved path to
`linkObject`. A caller may also pass an absolute or directly-existing path
verbatim. If no candidate exists, the caller reports `StdLibMissing` (ore) and
Ferro reports `RuntimeLibMissing` if the given path does not exist.

## Alternatives considered

1. **Pre-link `wfr_std` into a single relocatable object and have Ferro read
   that object.** Rejected: pre-linking presupposes a working linker (the very
   thing Ferro is), and a pre-linked object would already carry absolute
   addresses, conflicting with Ferro's relocation application.
2. **Ferro hunts for `wfr_std` itself (built-in default paths).** Rejected:
   violates "Determinism over Magic" — the caller controls where the runtime
   lives, and `linkObject`'s explicit `runtime_lib` argument keeps link
   semantics visible and testable.
3. **Have ore extract archive members and pass them individually.** Rejected:
   `linkObject` takes a single `runtime_lib` path; archive member extraction is
   Ferro's reader concern, not ore's.

## Consequences

### Positive

- `build.zig` is unchanged: `wfr_std` keeps its existing static-library
  target and install to `zig-out/lib`.
- One lookup strategy is shared across the old nasm/`zig cc` path and the new
  Ferro path, so behavior stays identical across the cutover.
- `RuntimeLibMissing` / `StdLibMissing` surface as ordinary errors through the
  Wolframite compiler, with no `ld` script parsing.

### Negative

- Ferro's object reader must understand the platform archive container
  (ELF `ar`, COFF lib) in addition to single object files.
- The link-description author must write the platform-appropriate archive
  name (`wfr_std.lib` vs `libwfr_std.a`); a mismatched name fails with
  `RuntimeLibMissing` rather than silently linking the wrong runtime.

## Related

- `libs/backend/docs/adr/adr_ferro_linker.md` — `linkObject` interface, `LinkOptions`, link stages.
- `libs/backend/docs/adr/adr_object_format.md` — ELF64 / PE/COFF object format, relocation types.
- `src/ore/link.zig` — `findWfrStdLib` (current lookup implementation) and `assembleAndLink`.
- `libs/std/src/std.zig` — the `wfr_std_*` runtime entry points.
