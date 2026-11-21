#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Line-based reading of workflows for the input-forwarding validators.

``validate_comment_fields_forwarding.py`` (#1677) and
``validate_comment_format_forwarding.py`` (#1678) read workflow and action
files line by line, as ``validate_comment_history_facades.py`` does: a job is
a two-space key under ``jobs``, a step is any ``- key:`` list item, and a
trailing ``#`` comment is allowed on the lines checked. This module holds
what they share. Standard library only.
"""

from __future__ import annotations

import re

#: Optional trailing comment and end of line.
TAIL = r"\s*(?:#.*)?$"
#: A ``uses:`` line calling a workflow; group 1 is the file name.
CALLS = re.compile(
    rf"^\s*(?:- )?uses: \S*?\.github/workflows/([A-Za-z0-9._-]+\.yml)(?:@\S+)?{TAIL}",
    re.M,
)
_UNIT_START = re.compile(r"^(?:  [A-Za-z0-9_-]+:\s*(?:#.*)?$|\s*- [A-Za-z_-]+:)")


def forward(name: str) -> str:
    """Return the pattern of ``${{ inputs.<name> }}``."""
    return rf"\$\{{\{{ inputs\.{name} \}}\}}"


def declares(name: str) -> dict[str, re.Pattern[str]]:
    """Return the patterns of an input declaration, by file kind."""
    return {
        "workflow": re.compile(rf"^      {name}:{TAIL}", re.M),
        "action": re.compile(rf"^  {name}:{TAIL}", re.M),
    }


def units(text: str) -> list[tuple[int, str]]:
    """Split a file into jobs and steps: (first line, text without comment lines)."""
    found: list[tuple[int, list[str]]] = [(1, [])]
    for number, line in enumerate(text.splitlines(), start=1):
        if _UNIT_START.match(line):
            found.append((number, []))
        if not line.lstrip().startswith("#"):
            found[-1][1].append(line)
    return [(start, "\n".join(lines)) for start, lines in found]
