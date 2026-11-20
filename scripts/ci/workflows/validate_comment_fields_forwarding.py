#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that comment posters and their wrappers pass comment-fields on (#1677).

Usage: validate_comment_fields_forwarding.py <repository-root>

Exits non-zero and prints each violation when:

- the ``post-pr-comment`` action does not declare ``comment-fields`` or does
  not pass it to its post step as ``COMMENT_FIELDS``;
- a ``reusable-*.yml`` step uses the ``post-pr-comment`` action without
  ``comment-fields: ${{ inputs.comment-fields }}``, or runs
  ``post-pr-comment.sh`` with ``STEP: post`` without
  ``COMMENT_FIELDS: ${{ inputs.comment-fields }}``;
- a ``reusable-*.yml`` job calls a workflow that declares ``comment-fields``
  without forwarding it;
- a ``reusable-*.yml`` that does any of these does not declare the input.

The workflows are read line by line, as the sibling
``validate_comment_history_facades.py`` reads them: jobs at two spaces, steps
as ``- `` items at six, inputs at six under ``workflow_call``.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

INPUT = "comment-fields"
ACTION = ".github/actions/post-pr-comment/action.yml"
_DECLARES = re.compile(rf"^      {INPUT}:\s*$", re.M)
_UNIT_START = re.compile(r"^(?:  [A-Za-z0-9_-]+:\s*$| {6}- )")
_USES_ACTION = re.compile(r"^\s+uses: \S*\.github/actions/post-pr-comment\s*$", re.M)
_RUNS_SCRIPT = re.compile(r"post-pr-comment\.sh")
_POST_STEP = re.compile(r"^\s+STEP: [\"']?post[\"']?\s*$", re.M)
_CALLS = re.compile(r"^    uses: \./\.github/workflows/(\S+\.yml)\s*$", re.M)
_WITH_FORWARD = re.compile(rf"^\s+{INPUT}: \$\{{\{{ inputs\.{INPUT} \}}\}}\s*$", re.M)
_ENV_FORWARD = re.compile(
    rf"^\s+COMMENT_FIELDS: \$\{{\{{ inputs\.{INPUT} \}}\}}\s*$",
    re.M,
)


def _units(text: str) -> list[tuple[int, str]]:
    """Split a workflow into jobs and steps: (first line number, text)."""
    units: list[tuple[int, list[str]]] = [(1, [])]
    for number, line in enumerate(text.splitlines(), start=1):
        if _UNIT_START.match(line):
            units.append((number, []))
        units[-1][1].append(line)
    return [(start, "\n".join(lines)) for start, lines in units]


def _action_problems(root: Path) -> list[str]:
    """Check the post-pr-comment action itself."""
    path = root / ACTION
    if not path.is_file():
        return [f"{ACTION}: not found"]
    text = path.read_text(encoding="utf-8")
    problems = []
    if not re.search(rf"^  {INPUT}:\s*$", text, re.M):
        problems.append(f"{ACTION}: does not declare {INPUT}")
    if not _ENV_FORWARD.search(text):
        problems.append(
            f"{ACTION}: does not pass {INPUT} to its post step as COMMENT_FIELDS",
        )
    return problems


def _workflow_problems(path: Path, declarers: set[str]) -> tuple[list[str], bool]:
    """Check one reusable workflow; also tell whether it posts or forwards."""
    text = path.read_text(encoding="utf-8")
    problems: list[str] = []
    needs_input = False
    for start, unit in _units(text):
        where = f"{path.name}:{start}"
        if _USES_ACTION.search(unit):
            needs_input = True
            if not _WITH_FORWARD.search(unit):
                problems.append(f"{where}: post-pr-comment step does not pass {INPUT}")
        elif _RUNS_SCRIPT.search(unit) and _POST_STEP.search(unit):
            needs_input = True
            if not _ENV_FORWARD.search(unit):
                problems.append(
                    f"{where}: post-pr-comment.sh post step does not set COMMENT_FIELDS"
                )
        called = _CALLS.search(unit)
        if called and called.group(1) in declarers:
            needs_input = True
            if not _WITH_FORWARD.search(unit):
                callee = called.group(1)
                problems.append(f"{where}: call to {callee} does not forward {INPUT}")
    if needs_input and not _DECLARES.search(text):
        problems.insert(0, f"{path.name}: does not declare {INPUT}")
    return problems, needs_input


def main(root: Path) -> int:
    """Report posters and wrappers that do not take and pass comment-fields.

    Args:
        root: Repository root holding ``.github``.

    Returns:
        int: 0 when every one conforms, else 1.
    """
    workflows = sorted((root / ".github" / "workflows").glob("reusable-*.yml"))
    declarers = set()
    for path in workflows:
        if _DECLARES.search(path.read_text(encoding="utf-8")):
            declarers.add(path.name)
    problems = _action_problems(root)
    posting = 0
    for path in workflows:
        found, needs_input = _workflow_problems(path, declarers)
        problems.extend(found)
        posting += needs_input
    if not posting:
        problems.append("no reusable workflow posts a comment through post-pr-comment")
    sys.stdout.write("".join(f"{problem}\n" for problem in problems))
    return int(bool(problems))


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1])))
