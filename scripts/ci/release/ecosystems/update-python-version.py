#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Update [project].version in pyproject.toml using tomlkit.

Preserves all formatting, comments, and table ordering. This is
deliberately used instead of sed to avoid matching the wrong
`version = "..."` line in other TOML sections.

Usage:
    python3 update-python-version.py <pyproject-path> <new-version>
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))

from toml_support import require_tomlkit  # noqa: E402

tomlkit = require_tomlkit()


def main() -> None:
    """Set ``[project].version`` in a pyproject.toml from ``sys.argv``.

    Reads the pyproject path and new version from ``sys.argv``. Exits with
    status 1 on usage errors, a missing file, unreadable/unparseable TOML,
    or a write failure.
    """
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <pyproject-path> <new-version>", file=sys.stderr)
        sys.exit(1)

    pyproject_path = Path(sys.argv[1])
    new_version = sys.argv[2]

    if not pyproject_path.is_file():
        print(f"ERROR: {pyproject_path} does not exist", file=sys.stderr)
        sys.exit(1)

    try:
        content = pyproject_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {pyproject_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        doc = tomlkit.parse(content)
    except ValueError as exc:
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
