#!/usr/bin/env python3
"""install-compiler.py — Install the Wolframite toolchain.

Copies the built artifacts from zig-out/ to the platform install location:

* Windows: %USERPROFILE%\wolframite\{bin,lib}  (ore.exe, Wolframite.exe, wfr_std.lib)
* Unix:    /usr/local/wolframite\{bin,lib} when root, else $HOME/wolframite\{bin,lib}
           (ore, Wolframite, libwfr_std.a)
"""
from __future__ import annotations

import os
import shutil
import stat
import sys
from pathlib import Path

ZIG_OUT = Path("zig-out")
BIN_SRC = ZIG_OUT / "bin"
LIB_SRC = ZIG_OUT / "lib"

BINARIES = ("ore", "Wolframite")
LIB_NAMES = {"windows": "wfr_std.lib", "posix": "libwfr_std.a"}


def is_windows() -> bool:
    return os.name == "nt"


def install_dir() -> Path:
    if is_windows():
        return Path(os.environ.get("USERPROFILE", str(Path.home()))) / "wolframite"
    if os.geteuid() == 0:
        return Path("/usr/local/wolframite")
    return Path.home() / "wolframite"


def main() -> int:
    if not is_windows():
        arch = os.uname().machine
        if arch not in ("x86_64"):
            print(f"Your arch ({arch}) isn't supported by Wolframite yet", file=sys.stderr)
            return 1

    install = install_dir()
    bin_dir = install / "bin"
    lib_dir = install / "lib"
    bin_dir.mkdir(parents=True, exist_ok=True)
    lib_dir.mkdir(parents=True, exist_ok=True)

    exe_suffix = ".exe" if is_windows() else ""

    # Copy binaries from zig-out/ to the install location
    for name in BINARIES:
        src = BIN_SRC / f"{name}{exe_suffix}"
        dst = bin_dir / f"{name}{exe_suffix}"
        if not src.is_file():
            print(f"missing built artifact: {src}", file=sys.stderr)
            return 1
        shutil.copy2(src, dst)
        if not is_windows():
            dst.chmod(dst.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    # Copy the runtime library next to bin so ore can resolve wfr_std
    lib_name = LIB_NAMES["windows" if is_windows() else "posix"]
    lib_src = LIB_SRC / lib_name
    if not lib_src.is_file():
        print(f"missing built artifact: {lib_src}", file=sys.stderr)
        return 1
    shutil.copy2(lib_src, lib_dir / lib_name)

    print(f"Successfully installed Wolframite to {install}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
