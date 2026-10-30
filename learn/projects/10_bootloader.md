# Project 10: x86 Bootloader via Ferro Linker

**Difficulty:** Hard (final project)  
**Status:** Not yet possible — teaches the Ferro linker story that is planned
but not yet implemented.  
**Teaches:** The Wolframite-facing link description, the Ferro linker, and how
formatted args are passed to the linker in Wolframite syntax.

## The goal (when implemented)

Write a tiny x86_64 bootloader in Wolframite that, when linked by Ferro and
booted, prints `Hello from Wolframite` to the screen. This is the capstone that
ties together everything: `struct`, `enum`, `match`, `comptime`, regions, and
the linker.

## Why this is not possible yet

Ferro (the internal linker, short for Ferrotungsten) is specified in
`libs/backend/docs/adr/adr_ferro_linker.md`. Today, Tungsten emits NASM
assembly and `ore` shells out to `nasm` + `zig cc`. The object emission +
Ferro pipeline is not yet complete, so you cannot
produce a bootable image from Wolframite yet.

This project describes what you will do once Ferro lands.

## What Ferro does

Ferro is Tungsten's internal linker. It takes:

- A Tungsten-emitted object file (ELF64 on Linux, PE/COFF on Windows).
- The Wolframite runtime archive `wfr_std`.
- A **link description** authored in Wolframite.

And produces a runnable executable. Ferro's interface (from the ADR):

```zig
pub fn linkObject(
    io: std.Io,
    gpa: std.mem.Allocator,
    object_path: []const u8,
    runtime_lib: []const u8,
    exe_path: []const u8,
    options: LinkOptions,
) !void
```

`LinkOptions` has: `target`, `entry_symbol` (default `_main`), `subsystem`
(Windows console/GUI), `debug`.

## The Wolframite link description

There is **no GNU linker script** and no external `ld`. Instead, link semantics
are expressed as a normal Wolframite program, compiled by the normal Wolframite
compiler pipeline, and handed to Ferro as structured arguments.

The link description (conceptual) describes
inputs, output, runtime lib, entry point, and sections:

```wfr
// link.wfr — the link description, compiled by the normal compiler
fn link_description() -> LinkDescription {
    return LinkDescription{
        .object = "bootloader.o",
        .runtime = "wfr_std",
        .output = "bootloader.img",
        .target = "x86_64-unknown-elf",   // or the platform target triple
        .entry = "_main",
        .sections = [
            { .name = ".text", .flags = "alloc|exec" },
            { .name = ".data", .flags = "alloc|write" },
            { .name = ".bss",  .flags = "alloc|write" },
        ],
    }
}
```

The formatted args (inputs, output, entry, sections, target) are passed to
Ferro as structured arguments — not parsed from an `ld` script.

## What the bootloader would look like

A bootloader has no operating system, no standard library, and no `main` in the
usual sense. Tungsten names the program entry `_main`, and Ferro synthesizes
the platform entry that calls `_main` (no external shim assembly).

Conceptual bootloader source (illustrative; VGA text-mode printing at
`0xB8000`):

```wfr
fn main() -> i32 {
    // VGA text buffer at 0xB8000
    let vid: &mut [u8; 80 * 25 * 2] = ...  // region/mapped memory

    let msg = "Hello from Wolframite"
    mut i: i32 = 0
    while i < msg.len() {
        vid[i * 2] = msg[i] as u8
        vid[i * 2 + 1] = 0x07  // light gray on black
        i = i + 1
    }

    // Halt
    loop {
        hlt()
    }
    return 0
}
```

## What you would do once Ferro is implemented

1. Write the bootloader source (`bootloader.wfr`).
2. Write the link description (`link.wfr`) describing the output image,
   entry `_main`, and sections.
3. Run:

```sh
# Conceptual command once Ferro + object emission are done:
zig build ore -- build --bootloader bootloader.wfr --link-description link.wfr
```

This compiles `bootloader.wfr` to an object, compiles `link.wfr` to extract the
link description, and feeds both to Ferro to produce a bootable image.

4. Run the image in an emulator (QEMU) or on real hardware and see:

```
Hello from Wolframite
```

## What this teaches

Even though you can't run it yet, this project reinforces:

- **`struct`** — the link description is a struct.
- **`enum`** — section flags and target types are enums.
- **`match`** — handling different target platforms.
- **`comptime`** — `@hasField`, `@sizeOf` for validating the link description.
- **Regions** — explicit allocation control, matching Ferro's "Explicit
  Allocation Control" principle.
- **The linker story** — link semantics expressed in Wolframite, not `ld` scripts.

## Reference documents

- `libs/backend/docs/adr/adr_ferro_linker.md` — Ferro name, interface, target
  handling, symbol naming (`_main`, `__gN`, `_fnN`).
- `libs/backend/docs/adr/adr_object_format.md` — ELF64 and PE/COFF object
  formats, relocation types, section layout.

## Checkpoint (when Ferro lands)

- [ ] A `.wfr` bootloader compiles to an object via Tungsten object emission.
- [ ] A Wolframite link description compiles and drives Ferro.
- [ ] Ferro links the object + `wfr_std` into a bootable image.
- [ ] The image prints `Hello from Wolframite` when booted.

## Next

You have completed the tutorial. Re-read any core section, revisit the projects,
and explore `examples/*.wfr` in the repo for more reference programs.
