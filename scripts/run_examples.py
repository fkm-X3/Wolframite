#!/usr/bin/env python3
"""Build and run every Wolframite example in examples/.

For each ``*.wfr`` file the script:

  1. builds it with ``ore build <file>`` (emits <file>.exe next to the source),
  2. runs the produced executable with ``ore run <file>``,
  3. records the outcome and prints a summary at the end.

Prerequisites: the Wolframite toolchain must be built (``zig build``) so that
the ``ore`` executable is available. The script looks for it, in order:

  * the ``--ore`` option / ``ORE`` environment variable,
  * ``ore`` on PATH,
  * ``zig-out/bin/ore.exe`` (or ``zig-out/bin/ore``) relative to the repo root.

An example counts as PASS when it compiles and its program runs to completion.
Examples that intentionally return a non-zero exit code (e.g. ``match.wfr``
returns 42) still pass — the exit code is printed for information. An example
counts as FAIL when ``ore build`` fails, or when ``ore run`` reports that the
executable could not be started or terminated abnormally.

Generated ``.exe`` files can be cleaned up afterwards with
``python clean_examples.py``.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EXAMPLES_DIR = REPO_ROOT / "examples"
ORE_CANDIDATES = (
    REPO_ROOT / "zig-out" / "bin" / "ore.exe",
    REPO_ROOT / "zig-out" / "bin" / "ore",
)

# Messages ore prints on stderr when it could not actually execute the
# program (as opposed to the program simply exiting with a non-zero code).
ORE_RUN_FAILURE_PHRASES = (
    "error: executable '",
    "error: could not start '",
    "error: program terminated abnormally",
)


def find_ore(override: str | None) -> str | None:
    """Locate the ore executable."""
    if override:
        return override
    env_ore = os.environ.get("ORE")
    if env_ore:
        return env_ore
    path_ore = shutil.which("ore")
    if path_ore:
        return path_ore
    for candidate in ORE_CANDIDATES:
        if candidate.is_file():
            return str(candidate)
    return None


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
    )


def ore_run_failed(result: subprocess.CompletedProcess[str]) -> bool:
    """True when ore could not execute the program, False when the program
    merely exited with a non-zero code."""
    if result.returncode == 0:
        return False
    return any(phrase in result.stderr for phrase in ORE_RUN_FAILURE_PHRASES)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build and run all Wolframite examples in examples/",
    )
    parser.add_argument(
        "--ore",
        default=None,
        help="path to the ore executable (default: auto-discover)",
    )
    parser.add_argument(
        "--no-build",
        action="store_true",
        help="skip compilation; only run already-built executables",
    )
    parser.add_argument(
        "--stop-on-failure",
        action="store_true",
        help="stop after the first example that fails to build or run",
    )
    args = parser.parse_args()

    ore = find_ore(args.ore)
    if ore is None:
        print(
            "error: could not find the ore executable. Build it with `zig build`, "
            "install it on PATH, or pass --ore.",
            file=sys.stderr,
        )
        return 2

    if not EXAMPLES_DIR.is_dir():
        print(f"error: examples directory not found: {EXAMPLES_DIR}", file=sys.stderr)
        return 2

    examples = sorted(EXAMPLES_DIR.glob("*.wfr"))
    if not examples:
        print(f"no .wfr examples found in {EXAMPLES_DIR}")
        return 0

    print(f"Using ore: {ore}\n")

    # link_description.wfr defines a linker-args struct and has no fn main,
    # so it is not a runnable example.
    excluded = {"link_description.wfr"}
    examples = [e for e in examples if e.name not in excluded]

    passed = failed = 0
    for example in examples:
        print(f"=== {example.name} ===", flush=True)

        if not args.no_build:
            build = run([ore, "build", str(example)], cwd=REPO_ROOT)
            if build.returncode != 0:
                if build.stdout:
                    print(build.stdout, end="")
                if build.stderr:
                    print(build.stderr, end="", file=sys.stderr)
                print(
                    f"FAIL: {example.name} — ore build exited with code "
                    f"{build.returncode}\n",
                    file=sys.stderr,
                )
                failed += 1
                if args.stop_on_failure:
                    return 1
                continue

        run_result = run([ore, "run", str(example)], cwd=REPO_ROOT)
        if run_result.stdout:
            print(run_result.stdout, end="")
        if run_result.stderr:
            print(run_result.stderr, end="", file=sys.stderr)

        if ore_run_failed(run_result):
            print(
                f"FAIL: {example.name} — ore run exited with code "
                f"{run_result.returncode}\n",
                file=sys.stderr,
            )
            failed += 1
        else:
            print(
                f"PASS: {example.name} — exited with code "
                f"{run_result.returncode}\n"
            )
            passed += 1

        if args.stop_on_failure and ore_run_failed(run_result):
            return 1

    total = passed + failed
    print(
        f"Ran {total} example(s): {passed} passed, {failed} failed"
    )
    if failed:
        print("Hint: run `python clean_examples.py` to remove generated .exe files.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
