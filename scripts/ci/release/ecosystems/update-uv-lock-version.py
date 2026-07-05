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
from typing import Any

try:
    import tomlkit
except ImportError:
    print(
        "ERROR: tomlkit is required. Install via: pip install tomlkit",
        file=sys.stderr,
    )
    sys.exit(1)

# Source table keys uv uses for local (non-registry) packages. The
# project's own entry always carries one of these, which disambiguates
# it from a same-name registry package elsewhere in the lockfile.
LOCAL_SOURCE_KEYS = ("editable", "virtual", "directory", "path")


def is_local_source(package: dict[str, Any]) -> bool:
    """Return True when a [[package]] entry has a local source.

    Args:
        package: A parsed ``[[package]]`` table from uv.lock.

    Returns:
        True if the entry's source is editable, virtual, directory, or path.
    """
    source = package.get("source") or {}
    return any(key in source for key in LOCAL_SOURCE_KEYS)


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

    matches = [p for p in packages if p.get("name") == package_name]
    if not matches:
        print(
            f"ERROR: package {package_name!r} not found in {lock_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    # Prefer the local project entry (editable/virtual/directory source)
    # so a same-name registry package earlier in the file is never
    # rewritten by mistake. Without a local marker, only a unique
    # name match is safe to update.
    local_matches = [p for p in matches if is_local_source(p)]
    if local_matches:
        targets = local_matches
    elif len(matches) == 1:
        targets = matches
    else:
        print(
            f"ERROR: multiple non-local {package_name!r} entries in "
            f"{lock_path}; cannot identify the project package",
            file=sys.stderr,
        )
        sys.exit(1)

    for package in targets:
        package["version"] = new_version

    try:
        lock_path.write_text(tomlkit.dumps(doc), encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot write {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
