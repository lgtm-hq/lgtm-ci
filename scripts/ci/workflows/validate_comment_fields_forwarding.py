#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that comment posters and their wrappers pass comment-fields on (#1677).

Usage: validate_comment_fields_forwarding.py <repository-root>

Exits non-zero and prints each violation when:

- the ``post-pr-comment`` action does not declare ``comment-fields`` or does
  not pass it to its post step as ``COMMENT_FIELDS``;
- a reusable workflow (``.github/workflows/reusable-*.yml``) or a composite
  action (``.github/actions/*/action.yml``):
  - has a step that uses an action declaring ``comment-fields`` (the
    ``post-pr-comment`` action among them, local or pinned
    ``owner/repo/...@ref``) without ``comment-fields: ${{ inputs.comment-fields }}``;
  - has a step that runs ``post-pr-comment.sh`` for posting (``STEP: post``,
    or no ``STEP`` at all, since post is the script's default) without
    ``COMMENT_FIELDS: ${{ inputs.comment-fields }}``;
  - has a job that calls a workflow declaring ``comment-fields`` without
    forwarding it;
  - does any of these without declaring the input.

Files are read line by line, as the sibling
``validate_comment_history_facades.py`` reads them: a job is a two-space key
under ``jobs``, a step is any ``- key:`` list item, and a trailing ``#``
comment is allowed on the lines checked.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

INPUT = "comment-fields"
POSTER = "post-pr-comment"
ACTION = f".github/actions/{POSTER}/action.yml"
_TAIL = r"\s*(?:#.*)?$"
_FORWARD = rf"\$\{{\{{ inputs\.{INPUT} \}}\}}"
_DECLARES = {
    "workflow": re.compile(rf"^      {INPUT}:{_TAIL}", re.M),
    "action": re.compile(rf"^  {INPUT}:{_TAIL}", re.M),
}
_UNIT_START = re.compile(r"^(?:  [A-Za-z0-9_-]+:\s*(?:#.*)?$|\s*- [A-Za-z_-]+:)")
_USES_ACTION = re.compile(
    rf"^\s*(?:- )?uses: \S*?\.github/actions/([A-Za-z0-9._-]+)(?:@\S+)?{_TAIL}",
    re.M,
)
_CALLS = re.compile(
    rf"^\s*(?:- )?uses: \S*?\.github/workflows/([A-Za-z0-9._-]+\.yml)(?:@\S+)?{_TAIL}",
    re.M,
)
_SCRIPT = re.compile(rf"{POSTER}\.sh")
_STEP = re.compile(r"^\s+STEP: [\"']?([A-Za-z-]+)[\"']?" + _TAIL, re.M)
_WITH_FORWARD = re.compile(rf"^\s+{INPUT}: {_FORWARD}{_TAIL}", re.M)
_ENV_FORWARD = re.compile(rf"^\s+COMMENT_FIELDS: {_FORWARD}{_TAIL}", re.M)


def _units(text: str) -> list[tuple[int, str]]:
    """Split a file into jobs and steps: (first line, text without comment lines)."""
    units: list[tuple[int, list[str]]] = [(1, [])]
    for number, line in enumerate(text.splitlines(), start=1):
        if _UNIT_START.match(line):
            units.append((number, []))
        if not line.lstrip().startswith("#"):
            units[-1][1].append(line)
    return [(start, "\n".join(lines)) for start, lines in units]


def _runs_post(unit: str) -> bool:
    """Tell whether a step runs ``post-pr-comment.sh`` for posting."""
    if not _SCRIPT.search(unit) or _USES_ACTION.search(unit):
        return False
    step = _STEP.search(unit)
    return step is None or step.group(1) == "post"


def _action_problems(root: Path) -> list[str]:
    """Check the post-pr-comment action itself."""
    path = root / ACTION
    if not path.is_file():
        return [f"{ACTION}: not found"]
    text = path.read_text(encoding="utf-8")
    problems = []
    if not _DECLARES["action"].search(text):
        problems.append(f"{ACTION}: does not declare {INPUT}")
    if not _ENV_FORWARD.search(text):
        problems.append(
            f"{ACTION}: does not pass {INPUT} to its post step as COMMENT_FIELDS",
        )
    return problems


def _unit_problems(
    where: str,
    unit: str,
    declarers: dict[str, set[str]],
) -> tuple[list[str], bool]:
    """Check one job or step; also tell whether it posts or forwards."""
    problems: list[str] = []
    needs_input = False
    action = _USES_ACTION.search(unit)
    called = _CALLS.search(unit)
    if action and action.group(1) in declarers["action"]:
        needs_input = True
        if not _WITH_FORWARD.search(unit):
            name = action.group(1)
            what = f"{POSTER} step" if name == POSTER else f"step using {name}"
            problems.append(f"{where}: {what} does not pass {INPUT}")
    elif _runs_post(unit):
        needs_input = True
        if not _ENV_FORWARD.search(unit):
            missing = "post step does not set COMMENT_FIELDS"
            problems.append(f"{where}: {POSTER}.sh {missing}")
    if called and called.group(1) in declarers["workflow"]:
        needs_input = True
        if not _WITH_FORWARD.search(unit):
            callee = called.group(1)
            problems.append(f"{where}: call to {callee} does not forward {INPUT}")
    return problems, needs_input


def _file_problems(
    target: tuple[Path, str, str],
    declarers: dict[str, set[str]],
) -> tuple[list[str], bool]:
    """Check one workflow or composite action; also tell whether it posts."""
    path, name, kind = target
    text = path.read_text(encoding="utf-8")
    problems: list[str] = []
    needs_input = False
    for start, unit in _units(text):
        found, posts = _unit_problems(f"{name}:{start}", unit, declarers)
        problems.extend(found)
        needs_input = needs_input or posts
    if needs_input and not _DECLARES[kind].search(text):
        problems.insert(0, f"{name}: does not declare {INPUT}")
    return problems, needs_input


def _targets(root: Path) -> list[tuple[Path, str, str]]:
    """The reusable workflows and composite actions to check: (path, name, kind)."""
    github = root / ".github"
    found = [
        (path, path.name, "workflow")
        for path in sorted((github / "workflows").glob("reusable-*.yml"))
    ]
    for path in sorted((github / "actions").glob("*/action.yml")):
        if path.parent.name != POSTER:
            found.append((path, f"actions/{path.parent.name}/action.yml", "action"))
    return found


def main(root: Path) -> int:
    """Report posters and wrappers that do not take and pass comment-fields.

    Args:
        root: Repository root holding ``.github``.

    Returns:
        int: 0 when every one conforms, else 1.
    """
    targets = _targets(root)
    declarers: dict[str, set[str]] = {"workflow": set(), "action": set()}
    if (root / ACTION).is_file():
        declarers["action"].add(POSTER)
    for path, _, kind in targets:
        if _DECLARES[kind].search(path.read_text(encoding="utf-8")):
            key = path.name if kind == "workflow" else path.parent.name
            declarers[kind].add(key)
    problems = _action_problems(root)
    posting = 0
    for target in targets:
        found, needs_input = _file_problems(target, declarers)
        problems.extend(found)
        posting += needs_input
    if not posting:
        problems.append("no reusable workflow posts a comment through post-pr-comment")
    sys.stdout.write("".join(f"{problem}\n" for problem in problems))
    return int(bool(problems))


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1])))
