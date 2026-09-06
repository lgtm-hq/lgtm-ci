#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read a field from pyproject.toml's [project] table.

Usage:
    python3 read-pyproject-field.py <pyproject-path> <field>

Examples:
    python3 read-pyproject-field.py pyproject.toml version
    python3 read-pyproject-field.py pyproject.toml name
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

import sys
from pathlib import Path

try:
    import tomllib
except ImportError:
    import tomli as tomllib  # type: ignore[no-redef]


def main() -> None:
    """Print a field from a pyproject.toml ``[project]`` table.

    Reads the pyproject path and field name from ``sys.argv``. Exits with
    status 1 on usage errors, a missing file, or unreadable/unparseable
    TOML; prints an empty string when the field is absent.
    """
    if len(sys.argv) != 3:
        print(
            f"Usage: {sys.argv[0]} <pyproject-path> <field>",
            file=sys.stderr,
        )
        sys.exit(1)

    pyproject_path = Path(sys.argv[1])
    field = sys.argv[2]

    if not pyproject_path.is_file():
        print(f"ERROR: {pyproject_path} does not exist", file=sys.stderr)
        sys.exit(1)

    try:
        with pyproject_path.open("rb") as f:
            data = tomllib.load(f)
    except OSError as exc:
        print(f"ERROR: cannot read {pyproject_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    except ValueError as exc:
        print(f"ERROR: failed to parse {pyproject_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    value = data.get("project", {}).get(field, "")
    print(value)


if __name__ == "__main__":
    main()
