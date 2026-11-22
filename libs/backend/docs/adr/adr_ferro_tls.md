# ADR: Ferro static thread-local storage

## Status

Accepted

## Date

23-11-2026

## Context

The Zig-built Wolframite runtime contains thread-local variables, including
`debug.panic_stage` and `Io.Threaded.Thread.current`. Ferro previously folded
ELF `.tdata`/`.tbss` into ordinary `.data`/`.bss`, discarded COFF `.tls$`
symbols, ignored `IMAGE_REL_AMD64_SECREL`, and treated the undefined
`_tls_index` as a code stub. Executables therefore had no valid per-thread
template or thread pointer. Preserving only the section bytes would not fix
this: TLS also requires platform relocations, loader metadata, and startup
initialization.

## Scope

- Static executables for x86_64 Windows and Linux.
- Initialized and zero-filled TLS from the program object and runtime archive.
- COFF `.tls$` and ELF `.tdata`/`.tbss` inputs.
- Local-exec access emitted by Zig: COFF `_tls_index` + SECREL and ELF
  `R_X86_64_TPOFF32`.
- Main-thread initialization before `_main`; runtime-created threads use the
  same Zig `area_desc` thereafter.

Dynamic TLS, shared objects, `dlopen`, general-dynamic/local-dynamic models,
PIE/ASLR, PE TLS callbacks, and non-x86_64 layouts are outside this contract.
Complete panic stack traces also require error-return and unwind support;
those are independent of TLS availability.

## Decision

### 1. TLS has a separate object and image representation

TLS is never merged into process-global `.data` or `.bss`.

`MergedImage` owns an initialized `tls` template plus `tls_zero_fill_size` and
`tls_alignment`. TLS symbols use the canonical section name `.tls`; their
values are offsets into that template, not virtual addresses. Archive merging
preserves alignment and rebases symbols and relocation sites consistently.

The relocation model has two additional kinds:

| Kind | Input | Value written |
|------|-------|---------------|
| `secrel32` | `IMAGE_REL_AMD64_SECREL` | Symbol's unsigned offset in the final TLS template |
| `tpoff32` | `R_X86_64_TPOFF32` | `symbol_offset + addend - alignUp(total_tls_size, tls_alignment)` |

A TLS relocation must target a TLS symbol, and ordinary address relocations
must not target TLS symbols. Unsupported storage/address combinations fail
with `RelocationFailed`; Ferro does not silently leave a TLS site unpatched.

### 2. Windows uses loader-managed static TLS

Ferro synthesizes a four-byte `_tls_index` cell in writable `.data` and
resolves all of its REL32 references to that cell. It emits a separate `.tls`
section containing the initialized template and writes a 40-byte
`IMAGE_TLS_DIRECTORY64` at the end of `.data`.

The TLS directory contains:

- `StartAddressOfRawData`: VA of `.tls`;
- `EndAddressOfRawData`: VA immediately after initialized bytes;
- `AddressOfIndex`: VA of `_tls_index`;
- `AddressOfCallBacks`: zero (no callbacks);
- `SizeOfZeroFill`: zero-filled tail size;
- `Characteristics`: zero.

PE data-directory entry 9 points to this structure. `.data` and `.tls` both
have `IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE`; in particular, the Windows
loader must be able to write `_tls_index` before entering the process. The
loader allocates and initializes each thread's copy, so no TLS-specific entry
code is required on Windows.

### 3. ELF separates the template from per-thread storage

For an image with TLS, Ferro emits:

1. An R/X PT_LOAD that includes the ELF/program headers and text;
2. A page-separated R/W PT_LOAD for ordinary data;
3. A read-only PT_LOAD containing only initialized TLS bytes;
4. A PT_TLS record for the same template.

The template PT_LOAD has equal file and memory sizes. PT_TLS may have a larger
memory size to describe `.tbss`; that tail is per-thread storage and is not a
zero-fill tail in the read-only file mapping. Text and writable data do not
share a page, so mapping data cannot remove execute permission from the entry
stub. The relocation layout includes the exact ELF-header, entry-stub, and
page-alignment adjustments.

### 4. Linux `_start` initializes the thread pointer before `_main`

The ELF entry stub calls `wfr_std_init_tls(phdrs, phnum)` before calling
`_main`. The runtime locates PT_TLS (and PT_PHDR when present), computes the
x86_64 variant-II `std.os.linux.tls.AreaDesc`, obtains a process-lifetime
anonymous mapping with raw `mmap`, then calls Zig's public `prepareArea` and
`setThreadPointer` functions.

The layout is: TLS block, aligned one-pointer ABI TCB, one-pointer Zig TCB,
and a two-pointer static DTV. Using raw mmap avoids allocator and error-return
machinery before FS is initialized. Zig still constructs the DTV/TCB contents
and installs the thread pointer; runtime-created threads reuse `area_desc`.

### 5. Validation covers semantics and execution

Unit tests cover COFF SECREL preservation, ELF TLS/zero-fill layout and TPOFF32
values, PE section permissions and the TLS directory, and ELF program headers
and startup bytes. Smoke tests build and run normal and assertion-failing
Wolframite programs on Windows and Linux, and inspect the resulting loader
metadata. A nonzero FS base after startup is required on Linux; merely having
PT_TLS in the file is not sufficient.

## Alternatives considered

1. **Fold TLS into `.data`/`.bss`.** Rejected: this creates one process-global
   copy and cannot satisfy thread-local addressing or initialization.
2. **Apply SECREL but skip the PE directory and `_tls_index`.** Rejected: the
   resulting code still has no valid module slot or per-thread template.
3. **Hand-roll a minimal Linux FS pointer without a DTV/TCB.** Rejected: it is
   incompatible with Zig's runtime and runtime-created threads.
4. **Use a general allocator before Linux TLS initialization.** Rejected:
   allocator and error-return paths may themselves require an initialized
   thread pointer. Raw mmap has no such dependency.

## Consequences

### Positive

- `debug.panic_stage`, `Io.Threaded.Thread.current`, and other static TLS are
  represented and addressed correctly.
- Windows initializes TLS through its loader; Linux initializes it explicitly
  before any runtime or program code that can access TLS.
- Unsupported TLS cases fail the link instead of producing silent corruption.
- Ordinary data permissions, ELF segment permissions, and text/data page
  boundaries are defined by the same layout used for relocation.

### Negative

- Ferro must keep TLS-specific sections, symbols, relocations, and writer
  metadata through every link stage rather than using a two-section model.
- Linux has a small runtime/entry-stub dependency on the program-header table.
- Full default-panic stack traces remain dependent on separate error-return
  and unwind support; TLS support alone does not provide them.

## Related

- `adr_ferro_linker.md` — overall link pipeline.
- `adr_object_format.md` — ELF64 and PE/COFF object contracts.
- `adr_runtime_archive.md` — runtime archive consumption.
