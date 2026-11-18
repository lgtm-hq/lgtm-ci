#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail on inline shell that is not a script call, a generated copy or trivial (#1624).

Usage: validate_inline_shell.py [--repo-root DIR] [--summary]

Shell belongs in a script file under ``scripts/``, where it is linted,
formatted and tested; a workflow or composite action calls it. This check
reads every ``run:`` step of ``.github/workflows/*.yml``/``*.yaml`` and
``.github/actions/**/action.yml``/``action.yaml`` and puts it in one of four
classes:

``script-call``
    One call to a script file, as ``inline_shell_rules.script_call`` defines.
``generated``
    A copy written by ``scripts/ci/bootstrap/sync_inline_blocks.py``: either
    the whole ``run:`` is one or more marked blocks with nothing hand-written
    around them, or the step sits inside a block that copies whole steps
    (``tooling-app-mint``). The marker id must be one the generator knows; its
    ``--check`` keeps the body equal to the tested source.
``trivial``
    Hand-written, and passes every condition of the trivial-step definition
    (``inline_shell_rules`` module docstring, docs/inline-shell.md).
``violation``
    Anything else. Each broken rule is printed as
    ``file:line: job / step: [rule N: title] what breaks it``, and the exit
    status is 1.

Rule 3 (no ``${{ }}`` in the script) applies to every step, whatever its
class. ``--summary`` also prints how many steps fall in each class.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from collections.abc import Iterator, Sequence
from dataclasses import dataclass, field
from enum import StrEnum, auto
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
for _path in (HERE, HERE.parent / "bootstrap"):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

# pylint: disable=wrong-import-position
import sync_inline_blocks  # noqa: E402
from inline_shell_rules import (  # noqa: E402
    MAX_COPIES,
    RULE_TITLES,
    Rule,
    expression_lines,
    normalized,
    script_call,
    trivial_problems,
)

# pylint: enable=wrong-import-position

ROOT = HERE.parents[2]
COMPOSITE = "(composite)"
STR_TAG = "tag:yaml.org,2002:str"
GENERATED_RULE = "generated"
MOVE_HINT = "Move the code to a script file under scripts/ (docs/inline-shell.md)."


class Category(StrEnum):
    """What a ``run:`` step is."""

    SCRIPT_CALL = "script-call"
    GENERATED = auto()
    TRIVIAL = auto()
    VIOLATION = auto()


@dataclass
class Step:  # pylint: disable=too-many-instance-attributes
    """One ``run:`` step and its verdict.

    Attributes:
        file: Path relative to the repository root.
        line: Line of the ``run:`` value in the file (1-based).
        job: The job id, or ``(composite)`` in an action.
        name: The step's name, else its id, else its index.
        run: The script text.
        category: The class it falls in.
        problems: ``(rule, message)`` per broken rule; a generated-block
            problem carries the rule ``generated`` instead of a number.
    """

    file: str
    line: int
    job: str
    name: str
    run: str
    category: Category = Category.VIOLATION
    problems: list[tuple[str, str]] = field(default_factory=list)

    def fail(self, rule: Rule | str, message: str) -> None:
        """Record a broken rule and mark the step a violation."""
        key = str(int(rule)) if isinstance(rule, Rule) else rule
        self.problems.append((key, message))
        self.category = Category.VIOLATION


def yaml_files(repo: Path) -> Iterator[Path]:
    """Yield every workflow and composite action file, sorted.

    Args:
        repo: The repository root.

    Yields:
        Paths of ``.github/workflows/*.y*ml`` and ``.github/actions/**/action.y*ml``.
    """
    workflows = repo / ".github" / "workflows"
    actions = repo / ".github" / "actions"
    yield from sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")])
    yield from sorted([*actions.rglob("action.yml"), *actions.rglob("action.yaml")])


def marker_ranges(text: str) -> tuple[list[tuple[int, int]], list[str]]:
    """Return the line ranges of the generated blocks in a file.

    Args:
        text: The file contents.

    Returns:
        ``(begin line, end line)`` per marker pair (1-based), and a message
        per unpaired, nested or unknown marker.
    """
    ranges: list[tuple[int, int]] = []
    errors: list[str] = []
    open_line, open_id = 0, ""
    for number, line in enumerate(text.splitlines(), start=1):
        match = sync_inline_blocks.MARKER.match(line)
        if match is None:
            continue
        kind, block_id = match["kind"], match["id"]
        if block_id not in sync_inline_blocks.BLOCKS:
            errors.append(f"line {number}: unknown generated block id {block_id!r}")
        if kind == "begin":
            if open_id:
                errors.append(f"line {number}: begin {block_id} inside {open_id}")
            open_line, open_id = number, block_id
        elif open_id != block_id:
            errors.append(f"line {number}: end {block_id} without its begin")
        else:
            ranges.append((open_line, number))
            open_line, open_id = 0, ""
    if open_id:
        errors.append(f"line {open_line}: begin {open_id} has no end")
    return ranges, errors


def _mapping(node: yaml.Node | None) -> dict[str, yaml.Node]:
    """Return a mapping node's scalar keys and value nodes."""
    if not isinstance(node, yaml.MappingNode):
        return {}
    fields: dict[str, yaml.Node] = {}
    for key, value in node.value:
        if isinstance(key, yaml.ScalarNode):
            fields[str(key.value)] = value
    return fields


def _step_groups(root: yaml.Node | None) -> Iterator[tuple[str, yaml.Node]]:
    """Yield ``(job id, steps node)`` for each job, or the composite action."""
    top = _mapping(root)
    for job_id, job in _mapping(top.get("jobs")).items():
        steps = _mapping(job).get("steps")
        if steps is not None:
            yield job_id, steps
    steps = _mapping(top.get("runs")).get("steps")
    if steps is not None:
        yield COMPOSITE, steps


def read_steps(text: str, relative: str) -> list[tuple[Step, yaml.Node]]:
    """Return the ``run:`` steps of one file with their step nodes.

    Args:
        text: The file contents.
        relative: The file's path relative to the repository root.

    Returns:
        The steps with their YAML step node.

    Raises:
        yaml.YAMLError: When the file does not parse.
    """
    root = yaml.compose(text, Loader=yaml.SafeLoader)
    found: list[tuple[Step, yaml.Node]] = []
    for job_id, steps in _step_groups(root):
        if not isinstance(steps, yaml.SequenceNode):
            continue
        for index, node in enumerate(steps.value):
            fields = _mapping(node)
            run = fields.get("run")
            if run is None:
                continue
            label = next(
                (
                    str(fields[key].value)
                    for key in ("name", "id")
                    if isinstance(fields.get(key), yaml.ScalarNode)
                ),
                str(index),
            )
            step = Step(relative, run.start_mark.line + 1, job_id, label, "")
            if isinstance(run, yaml.ScalarNode) and run.tag == STR_TAG:
                step.run = str(run.value)
            else:
                step.fail(Rule.ALLOW_LIST, "run: is not a plain string")
            found.append((step, node))
    return found


def _env_keys(node: yaml.Node) -> frozenset[str]:
    """Return the keys of a step's own ``env:``."""
    return frozenset(_mapping(_mapping(node).get("env")))


def outside_markers(script: str) -> list[str]:
    """Return the code lines of a script outside its generated blocks.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        Every non-blank line before, between or after the marker pairs.
    """
    outside: list[str] = []
    inside = False
    for line in script.splitlines():
        match = sync_inline_blocks.MARKER.match(line.rstrip())
        if match is not None:
            inside = match["kind"] == "begin"
        elif line.strip() and not inside:
            outside.append(line.strip())
    return outside


def classify(step: Step, node: yaml.Node, *, in_block: bool, repo: Path) -> None:
    """Put one step in its class, recording every broken rule.

    Args:
        step: The step; ``category`` and ``problems`` are set here.
        node: Its YAML step node, for the ``env:`` keys.
        in_block: True when the step lies inside a generated block of the file.
        repo: The repository root.
    """
    if step.problems:
        return
    for number in expression_lines(step.run):
        message = f"line {number}: a ${{{{ }}}} expression; pass it via env:"
        step.fail(Rule.EXPRESSION, message)
    if step.problems:
        # Fix the expression first; the other rules read the script without it.
        return
    lines = step.run.splitlines()
    marked = any(sync_inline_blocks.MARKER.match(line.rstrip()) for line in lines)
    if in_block or marked:
        outside = [] if in_block else outside_markers(step.run)
        if outside:
            message = f"hand-written code around a generated block: {outside[0]!r}"
            step.fail(GENERATED_RULE, message)
        else:
            step.category = Category.GENERATED
        return
    action_dir = Path(step.file).parent.as_posix() if step.job == COMPOSITE else None
    call = script_call(step.run, env=_env_keys(node), action_dir=action_dir, repo=repo)
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


def check(repo: Path) -> tuple[list[Step], list[str]]:
    """Classify every ``run:`` step in a repository.

    Args:
        repo: The repository root.

    Returns:
        Every step with its verdict, and file-level errors (a file that does
        not parse, a broken marker).
    """
    steps: list[Step] = []
    errors: list[str] = []
    for path in yaml_files(repo):
        relative = path.relative_to(repo).as_posix()
        text = path.read_text(encoding="utf-8")
        ranges, marker_errors = marker_ranges(text)
        errors.extend(f"{relative}: {message}" for message in marker_errors)
        try:
            found = read_steps(text, relative)
        except yaml.YAMLError as error:
            errors.append(f"{relative}: does not parse: {error}")
            continue
        for step, node in found:
            start = node.start_mark.line + 1
            in_block = any(begin < start < end for begin, end in ranges)
            classify(step, node, in_block=in_block, repo=repo)
            steps.append(step)
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
