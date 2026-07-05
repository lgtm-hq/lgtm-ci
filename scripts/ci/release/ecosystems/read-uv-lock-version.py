#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read the locked version of a named package from a uv.lock file.

Usage:
    python3 read-uv-lock-version.py <uv-lock-path> <package-name>

The package name must already be normalized the way uv records it in
uv.lock (PEP 503: lowercase, runs of ``-_.`` collapsed to a dash).
Prints an empty string when the package is not present.
"""

import sys
from pathlib import Path

try:
    import tomllib
except ImportError:
    import tomli as tomllib  # type: ignore[no-redef]


def main() -> None:
    if len(sys.argv) != 3:
        print(
            f"Usage: {sys.argv[0]} <uv-lock-path> <package-name>",
            file=sys.stderr,
        )
        sys.exit(1)

    lock_path = Path(sys.argv[1])
    package_name = sys.argv[2]

    if not lock_path.is_file():
        print(f"ERROR: {lock_path} does not exist", file=sys.stderr)
        sys.exit(1)

    try:
        with lock_path.open("rb") as f:
            data = tomllib.load(f)
    except OSError as exc:
        print(f"ERROR: cannot read {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"ERROR: failed to parse {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    version = ""
    for package in data.get("package", []):
        if package.get("name") == package_name:
            version = package.get("version", "")
            break
    print(version)


if __name__ == "__main__":
    main()
