#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that the test summary's comment-format reaches its renderer (#1678).

Usage: validate_comment_format_forwarding.py <repository-root>

The sibling of ``validate_comment_fields_forwarding.py``. Exits non-zero and
prints each violation when:

- ``reusable-publish-test-summary.yml``, which renders the test summary,
  does not declare ``comment-format``, or one of its steps that runs
  ``check-comment-format.sh`` or ``render-test-summary.sh`` does not set
  ``COMMENT_FORMAT: ${{ inputs.comment-format }}``;
- a reusable workflow (``.github/workflows/reusable-*.yml``) or a composite
  action (``.github/actions/*/action.yml``) has a job that calls a workflow
  declaring ``comment-format`` without
  ``comment-format: ${{ inputs.comment-format }}``, or does so without
  declaring the input itself.

Files are read line by line, as the sibling reads them: a job is a two-space
key under ``jobs``, a step is any ``- key:`` list item, and a trailing ``#``
comment is allowed on the lines checked.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:  # loaded by file (tests) or run with python3 -I
    sys.path.insert(0, _HERE)

# pylint: disable=wrong-import-position
from workflow_units import CALLS, TAIL, declares, forward, units  # noqa: E402

# pylint: enable=wrong-import-position

INPUT = "comment-format"
RENDERER = "reusable-publish-test-summary.yml"
SCRIPTS = ("check-comment-format.sh", "render-test-summary.sh")
_DECLARES = declares(INPUT)
_WITH_FORWARD = re.compile(rf"^\s+{INPUT}: {forward(INPUT)}{TAIL}", re.M)
_ENV_FORWARD = re.compile(rf"^\s+COMMENT_FORMAT: {forward(INPUT)}{TAIL}", re.M)


def _renderer_problems(root: Path) -> list[str]:
    """Check the workflow that renders the test summary."""
    path = root / ".github" / "workflows" / RENDERER
    if not path.is_file():
        return [f"{RENDERER}: not found"]
    text = path.read_text(encoding="utf-8")
    problems = []
    if not _DECLARES["workflow"].search(text):
        problems.append(f"{RENDERER}: does not declare {INPUT}")
    for script in SCRIPTS:
        needle = f"actions/{script}"
        steps = [(start, unit) for start, unit in units(text) if needle in unit]
        if not steps:
            problems.append(f"{RENDERER}: no step runs {script}")
        for start, unit in steps:
            if not _ENV_FORWARD.search(unit):
                miss = f"{script} step does not set COMMENT_FORMAT"
                problems.append(f"{RENDERER}:{start}: {miss}")
    return problems


def _file_problems(
    target: tuple[Path, str, str],
    declarers: set[str],
) -> tuple[list[str], bool]:
    """Check one workflow or composite action; also tell whether it forwards."""
    path, name, kind = target
    text = path.read_text(encoding="utf-8")
    problems: list[str] = []
    forwards = False
    for start, unit in units(text):
        called = CALLS.search(unit)
        callee = called.group(1) if called else ""
        if callee in declarers:
            forwards = True
            if not _WITH_FORWARD.search(unit):
                miss = f"call to {callee} does not forward {INPUT}"
                problems.append(f"{name}:{start}: {miss}")
    if forwards and not _DECLARES[kind].search(text):
        problems.insert(0, f"{name}: does not declare {INPUT}")
    return problems, forwards


def _targets(root: Path) -> list[tuple[Path, str, str]]:
    """The reusable workflows and composite actions to check: (path, name, kind)."""
    github = root / ".github"
    found = [
        (path, path.name, "workflow")
        for path in sorted((github / "workflows").glob("reusable-*.yml"))
    ]
    found += [
        (path, f"actions/{path.parent.name}/action.yml", "action")
        for path in sorted((github / "actions").glob("*/action.yml"))
    ]
    return found


def main(root: Path) -> int:
    """Report callers that do not take and pass comment-format on.

    Args:
        root: Repository root holding ``.github``.

    Returns:
        int: 0 when every one conforms, else 1.
    """
    targets = _targets(root)
    declarers = set()
    for path, _, kind in targets:
        text = path.read_text(encoding="utf-8")
        if kind == "workflow" and _DECLARES[kind].search(text):
            declarers.add(path.name)
    problems = _renderer_problems(root)
    forwarding = 0
    for path, name, kind in targets:
        found, forwards = _file_problems((path, name, kind), declarers)
        problems.extend(found)
        forwarding += forwards
    if not forwarding:
        problems.append(f"no reusable workflow forwards {INPUT} to {RENDERER}")
    sys.stdout.write("".join(f"{problem}\n" for problem in problems))
    return int(bool(problems))


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1])))
