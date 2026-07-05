#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Update the own-package version in a uv.lock file using tomlkit.

Fallback for environments where the ``uv`` binary is unavailable and
``uv lock`` cannot regenerate the lockfile. Only rewrites the
``version`` field of the named ``[[package]]`` entry; it does NOT
re-resolve dependencies or refresh any other lockfile metadata.

Preserves all formatting, comments, and table ordering.

Usage:
    python3 update-uv-lock-version.py <uv-lock-path> <package-name> <new-version>

The package name must already be normalized the way uv records it in
uv.lock (PEP 503: lowercase, runs of ``-_.`` collapsed to a dash).
"""

import sys
from pathlib import Path

try:
    import tomlkit
except ImportError:
    print(
        "ERROR: tomlkit is required. Install via: pip install tomlkit",
        file=sys.stderr,
    )
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 4:
        print(
            f"Usage: {sys.argv[0]} <uv-lock-path> <package-name> <new-version>",
            file=sys.stderr,
        )
        sys.exit(1)

    lock_path = Path(sys.argv[1])
    package_name = sys.argv[2]
    new_version = sys.argv[3]

    if not lock_path.is_file():
        print(f"ERROR: {lock_path} does not exist", file=sys.stderr)
        sys.exit(1)

    try:
        content = lock_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        doc = tomlkit.parse(content)
    except Exception as exc:
        print(f"ERROR: failed to parse {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    packages = doc.get("package")
    if packages is None:
        print(f"ERROR: no [[package]] entries in {lock_path}", file=sys.stderr)
        sys.exit(1)

    updated = False
    for package in packages:
        if package.get("name") == package_name:
            package["version"] = new_version
            updated = True
            break

    if not updated:
        print(
            f"ERROR: package {package_name!r} not found in {lock_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        lock_path.write_text(tomlkit.dumps(doc), encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot write {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
