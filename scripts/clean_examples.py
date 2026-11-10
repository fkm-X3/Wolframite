from __future__ import annotations

import argparse
from pathlib import Path

EXAMPLES_DIR = Path(__file__).resolve().parent.parent / "examples"
EXTENSIONS = {".obj", ".exe", ".ir"}


def clean(dry_run: bool = False) -> tuple[int, int]:
    if not EXAMPLES_DIR.exists():
        print(f"examples dir not found: {EXAMPLES_DIR}")
        return 0, 0

    removed = 0
    skipped = 0
    for path in EXAMPLES_DIR.rglob("*"):
        if path.is_file() and path.suffix.lower() in EXTENSIONS:
            if dry_run:
                print(f"[dry-run] would remove: {path}")
                removed += 1
            else:
                try:
                    path.unlink()
                    print(f"removed: {path}")
                    removed += 1
                except OSError as exc:
                    print(f"skipped {path}: {exc}")
                    skipped += 1
    return removed, skipped


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Delete .obj, .exe, .ir files from examples/"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="list files that would be removed without deleting them",
    )
    args = parser.parse_args()

    removed, skipped = clean(dry_run=args.dry_run)
    print(f"\n{removed} file(s) removed, {skipped} skipped.")


if __name__ == "__main__":
    main()
