#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail on inline shell that is not a script call, a generated copy or trivial (#1624).

Usage: validate_inline_shell.py [--repo-root DIR] [--summary]

Shell belongs in a script file under ``scripts/``, where it is linted,
formatted and tested; a workflow or composite action calls it. This check
reads every ``run:`` step of ``.github/workflows/*.yml``/``*.yaml``,
``examples/*.yml``/``*.yaml`` and ``.github/actions/**/action.yml``/
``action.yaml`` and puts it in one of four classes:

``script-call``
    One call to a script file, as ``inline_shell_calls`` defines.
``generated``
    A copy written by ``scripts/ci/bootstrap/sync_inline_blocks.py``: either
    the whole ``run:`` is one or more marked blocks with nothing hand-written
    around them, or the step sits inside a block that copies whole steps
    (``tooling-app-mint``). Each marker id must be one the generator knows,
    and each body must equal what the generator writes from the source in
    the checked tree; this check compares them itself.
``trivial``
    Hand-written, and passes every condition of the trivial-step definition
    (``inline_shell_trivial``, docs/inline-shell.md).
``violation``
    Anything else. Each broken rule is printed as
    ``file:line: job / step: [rule N: title] what breaks it``, and the exit
    status is 1.

Every step, whatever its class, must run under ``bash`` or ``sh``, must not
have an ``env:`` that moves a runner path (``inline_shell_rules.PROTECTED_ENV``),
and rule 3 (no ``${{ }}`` in the script) applies to it. ``--summary`` also
prints how many steps fall in each class.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from collections.abc import Sequence
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
for _path in (HERE, HERE.parent / "bootstrap"):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

# pylint: disable=wrong-import-position
import sync_inline_blocks  # noqa: E402
from inline_shell_calls import script_call  # noqa: E402
from inline_shell_rules import (  # noqa: E402
    MAX_COPIES,
    RULE_TITLES,
    Rule,
    character_problems,
    expression_lines,
    normalized,
    setting_problems,
)
from inline_shell_steps import (  # noqa: E402
    GENERATED_RULE,
    BlockError,
    Category,
    Step,
    block_bodies,
    outside_markers,
    read_steps,
    run_lines,
    scan_blocks,
    yaml_files,
)
from inline_shell_trivial import trivial_problems  # noqa: E402

# pylint: enable=wrong-import-position

__all__ = ["Category", "Step", "check", "classify", "main", "report", "summary"]

ROOT = HERE.parents[2]
MOVE_HINT = "Move the code to a script file under scripts/ (docs/inline-shell.md)."


def classify(
    step: Step,
    *,
    in_block: bool,
    repo: Path,
    bodies: dict[str, list[str]] | None = None,
) -> None:
    """Put one step in its class, recording every broken rule.

    Args:
        step: The step; ``category`` and ``problems`` are set here.
        in_block: True when the step lies inside a generated block of the file.
        repo: The repository root.
        bodies: The generated body per block id, else read from ``repo``.
    """
    if step.problems:
        return
    for message in setting_problems(step.context):
        step.fail(Rule.ALLOW_LIST, message)
    for number in expression_lines(step.run):
        message = f"line {number}: a ${{{{ }}}} expression; pass it via env:"
        step.fail(Rule.EXPRESSION, message)
    if step.problems:
        # Fix these first; the other rules read the script as bash without them.
        return
    lines = step.run.splitlines()
    marked = any(sync_inline_blocks.MARKER.match(line.rstrip()) for line in lines)
    if in_block:
        # A whole step copied by a YAML-level block; check() compares the file.
        step.category = Category.GENERATED
        return
    if marked:
        _classify_generated(step, block_bodies(repo) if bodies is None else bodies)
        return
    _classify_hand_written(step, repo)


def _classify_generated(step: Step, bodies: dict[str, list[str]]) -> None:
    """Accept a marked ``run:`` whose blocks equal their sources, and nothing else.

    The blocks are read from the parsed ``run:``, the text bash runs, so the
    YAML quoting of the value cannot hide a changed body.
    """
    outside = outside_markers(step.run)
    if outside:
        message = f"hand-written code around a generated block: {outside[0]!r}"
        step.fail(GENERATED_RULE, message)
    for error in scan_blocks(step.run, bodies)[1]:
        step.fail(GENERATED_RULE, f"in run: {error.message}")
    if not step.problems:
        step.category = Category.GENERATED


def _classify_hand_written(step: Step, repo: Path) -> None:
    """Class a hand-written step as a script call, trivial or a violation."""
    for message in character_problems(step.run):
        step.fail(Rule.ALLOW_LIST, message)
    if step.problems:
        return
    call = script_call(step.run, step.context, repo)
    if call.ok:
        step.category = Category.SCRIPT_CALL
        return
    found = trivial_problems(step.run)
    if found and call.shaped:
        # One command that runs a file: say why it is not an accepted call.
        step.fail(Rule.ALLOW_LIST, f"not a script call: {call.reason}")
        return
    for problem in found:
        step.fail(problem.rule, problem.message)
    if not step.problems:
        step.category = Category.TRIVIAL


def _attach(steps: Sequence[Step], blocks: Sequence[BlockError]) -> list[BlockError]:
    """Fail each generated step a block error covers; return the errors left over."""
    left: list[BlockError] = []
    for error in blocks:
        hit = [
            step
            for step in steps
            if step.span[0] <= error.last
            and error.first <= step.span[1]
            and step.category in {Category.GENERATED, Category.VIOLATION}
        ]
        for step in hit:
            step.fail(GENERATED_RULE, error.message)
        if not hit:
            left.append(error)
    return left


def check(repo: Path) -> tuple[list[Step], list[str]]:
    """Classify every ``run:`` step in a repository.

    Args:
        repo: The repository root.

    Returns:
        Every step with its verdict, and file-level errors (a file that does
        not parse, a broken marker or copy outside any step).
    """
    steps: list[Step] = []
    errors: list[str] = []
    bodies = block_bodies(repo)
    for path in yaml_files(repo):
        relative = path.relative_to(repo).as_posix()
        text = path.read_text(encoding="utf-8")
        try:
            found = read_steps(text, relative)
        except yaml.YAMLError as error:
            errors.append(f"{relative}: does not parse: {error}")
            continue
        # Blocks in a run: are checked in the parsed value (classify).
        ranges, blocks = scan_blocks(text, bodies, skip=run_lines(found))
        for step in found:
            in_block = any(begin < step.span[0] < end for begin, end in ranges)
            classify(step, in_block=in_block, repo=repo, bodies=bodies)
        left = _attach(found, blocks)
        errors.extend(f"{relative}: {error.message}" for error in left)
        steps.extend(found)
    count_copies(steps)
    return steps, errors


def count_copies(steps: Sequence[Step]) -> None:
    """Fail every trivial step whose code is in ``MAX_COPIES`` or more steps.

    Args:
        steps: Classified steps; the copies are marked violations here.
    """
    groups: dict[str, list[Step]] = defaultdict(list)
    for step in steps:
        if step.category is Category.TRIVIAL:
            groups[normalized(step.run)].append(step)
    for group in groups.values():
        if len(group) >= MAX_COPIES:
            for step in group:
                step.fail(
                    Rule.COPIES,
                    f"the same code is in {len(group)} steps; make it one script file",
                )


def report(steps: Sequence[Step], errors: Sequence[str]) -> list[str]:
    """Return one line per broken rule and file-level error.

    Args:
        steps: Classified steps.
        errors: File-level errors.

    Returns:
        The lines, in file order.
    """
    lines = [f"{error} [{GENERATED_RULE}]" for error in errors]
    for step in steps:
        for rule, message in step.problems:
            if rule == GENERATED_RULE:
                title = "generated copy"
            else:
                title = f"rule {rule}: {RULE_TITLES[Rule(int(rule))]}"
            where = f"{step.file}:{step.line}: {step.job} / {step.name}"
            lines.append(f"{where}: [{title}] {message}")
    return lines


def summary(steps: Sequence[Step]) -> list[str]:
    """Return the number of steps per class.

    Args:
        steps: Classified steps.

    Returns:
        One ``class: count`` line per class, then the total.
    """
    counts = Counter(step.category for step in steps)
    lines = [f"{category.value}: {counts[category]}" for category in Category]
    lines.append(f"total: {len(steps)}")
    return lines


def main(argv: Sequence[str] | None = None) -> int:
    """Run the check.

    Args:
        argv: Command-line arguments, defaulting to ``sys.argv[1:]``.

    Returns:
        0 when every step is accepted, 1 otherwise.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--summary", action="store_true", help="print counts per class")
    args = parser.parse_args(argv)
    steps, errors = check(args.repo_root)
    if args.summary:
        print("\n".join(summary(steps)))
    lines = report(steps, errors)
    if lines:
        print("Inline shell that is not a script call, a generated copy or trivial:")
        print("\n".join(lines))
        print(MOVE_HINT)
        return 1
    print("OK: every run: step is a script call, a generated copy or trivial")
    return 0


if __name__ == "__main__":
    sys.exit(main())
