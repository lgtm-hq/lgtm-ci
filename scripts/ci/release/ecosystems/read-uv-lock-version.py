#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read the locked version of a named package from a uv.lock file.

Usage:
    python3 read-uv-lock-version.py <uv-lock-path> <package-name> [--local-only]

The package name must already be normalized the way uv records it in
uv.lock (PEP 503: lowercase, runs of ``-_.`` collapsed to a dash).
Prints an empty string when the package is not present. With
``--local-only``, only local (editable/virtual/directory/path/workspace) entries
are considered — used to test whether a lockfile locks the project as
a workspace member.
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

import sys
from pathlib import Path

try:
    from toml_support import is_local_source
except ImportError:  # standalone execution: bootstrap the vendored lib/ path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
    from toml_support import is_local_source

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ImportError:
        print(
            "ERROR: tomllib (Python >= 3.11) or tomli is required.",
            file=sys.stderr,
        )
        sys.exit(1)


def main() -> None:
    """Print the locked version of the named package from a uv.lock file.

    Reads the lock path, package name, and optional ``--local-only`` flag
    from ``sys.argv``. Exits with status 1 on usage errors, a missing
    lockfile, or unreadable/unparseable TOML; prints an empty string when
    the package is not present.
    """
    args = sys.argv[1:]
    local_only = "--local-only" in args
    args = [a for a in args if a != "--local-only"]
    if len(args) != 2:
        print(
            f"Usage: {sys.argv[0]} <uv-lock-path> <package-name> [--local-only]",
            file=sys.stderr,
        )
        sys.exit(1)

    lock_path = Path(args[0])
    package_name = args[1]

    if not lock_path.is_file():
        print(f"ERROR: {lock_path} does not exist", file=sys.stderr)
        sys.exit(1)

    try:
        with lock_path.open("rb") as f:
            data = tomllib.load(f)
    except OSError as exc:
        print(f"ERROR: cannot read {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    except ValueError as exc:
        print(f"ERROR: failed to parse {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    # Mirror update-uv-lock-version.py: prefer the local project entry
    # so verification reads the same entry the updater wrote.
    matches = [p for p in data.get("package", []) if p.get("name") == package_name]
    local_matches = [p for p in matches if is_local_source(p)]
    selected = local_matches if local_only else (local_matches or matches)
    version = selected[0].get("version", "") if selected else ""
    print(version)


if __name__ == "__main__":
    main()
