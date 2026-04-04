#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Update [project].version in pyproject.toml using tomlkit.

Preserves all formatting, comments, and table ordering. This is
deliberately used instead of sed to avoid matching the wrong
`version = "..."` line in other TOML sections.

Usage:
    python3 update-python-version.py <pyproject-path> <new-version>
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
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <pyproject-path> <new-version>", file=sys.stderr)
        sys.exit(1)

    pyproject_path = Path(sys.argv[1])
    new_version = sys.argv[2]

    if not pyproject_path.exists():
        print(f"ERROR: {pyproject_path} does not exist", file=sys.stderr)
        sys.exit(1)

    try:
        content = pyproject_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {pyproject_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        doc = tomlkit.parse(content)
    except Exception as exc:
        print(f"ERROR: failed to parse {pyproject_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    project = doc.get("project")
    if project is None:
        print(f"ERROR: no [project] table in {pyproject_path}", file=sys.stderr)
        sys.exit(1)

    if "version" not in project:
        print(
            f"ERROR: no version key in [project] table of {pyproject_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    project["version"] = new_version

    try:
        pyproject_path.write_text(tomlkit.dumps(doc), encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot write {pyproject_path}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
