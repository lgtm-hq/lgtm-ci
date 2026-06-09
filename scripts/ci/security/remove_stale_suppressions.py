#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Remove stale [[IgnoredVulns]] blocks from .osv-scanner.toml.

Preserves all non-IgnoredVulns sections (for example [PackageOverrides]) and
per-entry comments by rewriting only matching array-of-tables blocks.

Usage:
    REMOVE_IDS_JSON='["GHSA-abc"]' python3 remove_stale_suppressions.py path.toml

Environment:
    REMOVE_IDS_JSON  JSON array of vulnerability IDs to remove (required)
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

_ID_PATTERN = re.compile(r'^id\s*=\s*"([^"]+)"')


def remove_stale_ignored_vulns(
    content: str,
    remove_ids: set[str],
) -> tuple[str, set[str]]:
    """Drop [[IgnoredVulns]] blocks whose id is in remove_ids.

    Args:
        content: Full TOML file contents.
        remove_ids: Vulnerability IDs to remove.

    Returns:
        Tuple of rewritten content and the set of IDs actually removed.
    """
    lines = content.splitlines(keepends=True)
    out: list[str] = []
    removed: set[str] = set()
    index = 0

    while index < len(lines):
        if lines[index].strip() != "[[IgnoredVulns]]":
            out.append(lines[index])
            index += 1
            continue

        block_lines = [lines[index]]
        index += 1

        while index < len(lines):
            stripped = lines[index].strip()
            if stripped.startswith("["):
                break
            block_lines.append(lines[index])
            index += 1

        vuln_id: str | None = None
        for block_line in block_lines:
            match = _ID_PATTERN.match(block_line.strip())
            if match:
                vuln_id = match.group(1)
                break

        if vuln_id is not None and vuln_id in remove_ids:
            removed.add(vuln_id)
        else:
            out.extend(block_lines)

    return "".join(out), removed


def main() -> None:
    """Entry point."""
    if len(sys.argv) != 2:
        print(
            "Usage: REMOVE_IDS_JSON='[...]' remove_stale_suppressions.py <toml-path>",
            file=sys.stderr,
        )
        sys.exit(1)

    toml_path = Path(sys.argv[1])
    remove_ids = set(json.loads(os.environ["REMOVE_IDS_JSON"]))
    original = toml_path.read_text()
    rewritten, removed = remove_stale_ignored_vulns(original, remove_ids)

    if rewritten != original:
        toml_path.write_text(rewritten)

    for vuln_id in sorted(removed):
        print(f"Removed: {vuln_id}", file=sys.stderr)


if __name__ == "__main__":
    main()
