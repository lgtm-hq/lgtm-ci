#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read a field from pyproject.toml's [project] table.

Usage:
    python3 read-pyproject-field.py <pyproject-path> <field>

Examples:
    python3 read-pyproject-field.py pyproject.toml version
    python3 read-pyproject-field.py pyproject.toml name
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
            f"Usage: {sys.argv[0]} <pyproject-path> <field>",
            file=sys.stderr,
        )
        sys.exit(1)

    pyproject_path = Path(sys.argv[1])
    field = sys.argv[2]

    if not pyproject_path.exists():
        sys.exit(1)

    with pyproject_path.open("rb") as f:
        data = tomllib.load(f)

    value = data.get("project", {}).get(field, "")
    print(value)


if __name__ == "__main__":
    main()
