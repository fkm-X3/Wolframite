# Wolframite Runtime (`libs/std`)

The libc-free Wolframite runtime. This is what a compiled program links against:
every entry point in `src/std.zig` is `export`ed with the platform's native C ABI,
which is the shape the compiler's extern-call lowering expects. Prelude functions such
as `print` lower to direct calls into this archive, and `ore` links it alongside the
program's NASM-assembled object files.

There is no libc here. Output goes to the kernel directly and the runtime never
allocates: each entry point either takes caller-owned memory or formats into a
fixed-size stack buffer.

## Building

The root `build.zig` builds this as the static library `wfr_std` and installs it to
`zig-out/lib` (`wfr_std.lib` on Windows, `libwfr_std.a` on ELF targets).
`src/ore/link.zig` looks for that archive and passes it to `zig cc`.

The library also builds standalone:

```bash
cd libs/std
zig build          # wfr_std.lib
zig build test     # 22 runtime tests
```

Requires Zig **0.16.0**.

## Export surface

Symbol names are `wfr_std_<name>`. The mapping from a Wolframite name to one of these
lives in `compiler/prelude.zig`, so renaming anything here is a breaking change there.

Conventions:

- `void` really returns void.
- Fallible entry points return `i64`: a nonnegative byte count, or `-1` when the OS
  refused the transfer.
- Predicates return `i32` (`1`/`0`), since an extern signature has no portable bool.

| Symbol | Signature | Notes |
|---|---|---|
| `wfr_std_print` | `void (*const String)` | The prelude's `print`. Writes the bytes plus a newline to stdout. |
| `wfr_std_write_string` | `void (*const String)` | Same, without the newline. |
| `wfr_std_write_bytes` | `void ([*]const u8, usize)` | Raw byte write to stdout. |
| `wfr_std_print_i64` | `void (i64)` | Decimal plus newline. |
| `wfr_std_print_u64` | `void (u64)` | Decimal plus newline. |
| `wfr_std_print_f64` | `void (f64)` | Decimal plus newline. |
| `wfr_std_print_hex` | `void (u64)` | `0x`-prefixed hex plus newline. |
| `wfr_std_write` | `i64 (i64, [*]const u8, usize)` | Write to a handle; bytes written or `-1`. |
| `wfr_std_read` | `i64 (i64, [*]u8, usize)` | Read from a handle; bytes read, `0` at EOF, or `-1`. |
| `wfr_std_flush` | `void ()` | No-op — the runtime never buffers across calls. |
| `wfr_std_exit` | `noreturn (i32)` | Terminate with an exit status. |
| `wfr_std_string_len` | `i64 (*const String)` | Header length field. |
| `wfr_std_string_eq` | `i32 (*const String, *const String)` | Byte-wise equality, not address equality. |
| `wfr_std_panic` | `noreturn (*const String)` | `panic: <msg>` to stderr, exit status `1`. |
| `wfr_std_memcpy` | `i64 ([*]u8, [*]const u8, usize)` | Byte copy, returns the count. |

Only `wfr_std_print` is reachable from the prelude today. The rest exist for a future
stdlib layer.

## String layout

A Wolframite `String` is a 16-byte header:

```text
[offset 0]  i64   len
[offset 8]  [*]u8 data
```

`abi.zig` defines it plus `stringFrom`/`bytesOf`. The compiler emits this exact
representation (`compiler/codegen/string.zig`). `len` is authoritative: nothing here
looks for a trailing NUL, so embedded NULs survive a round trip.

## Platform notes

`os.zig` is the only platform-aware file.

- **Windows**: direct `extern "kernel32"` imports — `GetStdHandle`, `WriteFile`,
  `ReadFile`, `ExitProcess`.
- **Linux**: `std.os.linux` raw syscalls — `write`, `read`, `exit`.

`writeAll` loops over short writes, which is normal on a pipe, and retries `EINTR`
rather than reporting a truncated write. Transfers are capped at 1 MiB per OS call so
the loop behaves identically on both platforms. Windows-only targets are otherwise
unsupported and fail at comptime.

## Tests

`zig build test-std` from the repository root, or `zig build test` in this directory,
runs 22 tests covering the String ABI, integer/hex/float formatting, short-write and
error paths on rejected handles, and the platform handle layer. The suite compiles
against both the Windows and Linux code paths under the native target.

There is deliberately no test that writes to stdout: the runtime writes straight to
the process's real stdout, which the Zig test runner is itself using for its
protocol, so such a test deadlocks the runner. Printing is covered end to end by
`ore run examples/hello.wfr` instead.
