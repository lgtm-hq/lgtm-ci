# SPDX-License-Identifier: MIT
"""Read the ``run:`` steps and generated blocks of workflow and action files (#1624).

``validate_inline_shell.py`` classifies what this module reads: each step with
its YAML context (:class:`inline_shell_rules.StepContext`), and each
``lgtm-ci-inline`` marker pair checked against the body
``scripts/ci/bootstrap/sync_inline_blocks.py`` would write. The check compares
every copy with its source itself, in actions too, which the generator's
``--check`` does not read.

A copy in a ``run:`` is read from the parsed value, the text bash runs, so the
YAML quoting (``|``, ``>``, ``"..."``, ``'...'``) cannot hide a changed body.
Only markers outside every ``run:`` value, around whole steps or ``env:``
entries, are read from the file text.

Every site tests a line with :func:`marker` and splits a ``run:`` value with
:func:`inline_shell_rules.script_lines`, on ``\n`` only, as bash does:
``str.splitlines`` also breaks at ``\r``, ``\v``, ``\f``, ``\x85`` and
U+2028, so a copy whose
``echo`` and ``exit 1`` lines are joined by one of them would read as equal
to its source while bash runs one ``echo`` line and never exits.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from dataclasses import dataclass, field
from enum import StrEnum, auto
from pathlib import Path

import sync_inline_blocks
import yaml
from inline_shell_context import (
    COMPOSITE,
    STR_TAG,
    mapping,
    step_context,
    step_groups,
    step_label,
)
from inline_shell_rules import Rule, StepContext, script_lines

GENERATED_RULE = "generated"


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
        span: First and last line of the step in the file (1-based).
        run_lines: First and last line of the ``run:`` value in the file.
        context: What the step's YAML says about how the script runs.
        category: The class it falls in.
        problems: ``(rule, message)`` per broken rule; a generated-block
            problem carries the rule ``generated`` instead of a number.
    """

    file: str
    line: int
    job: str
    name: str
    run: str
    span: tuple[int, int] = (0, 0)
    run_lines: tuple[int, int] = (0, 0)
    context: StepContext = field(default_factory=StepContext)
    category: Category = Category.VIOLATION
    problems: list[tuple[str, str]] = field(default_factory=list)

    def fail(self, rule: Rule | str, message: str) -> None:
        """Record a broken rule and mark the step a violation."""
        key = str(int(rule)) if isinstance(rule, Rule) else rule
        self.problems.append((key, message))
        self.category = Category.VIOLATION


@dataclass(frozen=True)
class BlockError:
    """A marker or a generated body that is wrong.

    Attributes:
        first: First line it covers in the file (1-based).
        last: Last line it covers.
        message: What is wrong.
    """

    first: int
    last: int
    message: str


def marker(line: str) -> re.Match[str] | None:
    """Return the match when a line is an ``lgtm-ci-inline`` marker, else None.

    The one marker test of the check. Spaces and tabs may follow the id; a
    line ending in ``\r`` or another control character is not a marker, and
    the character rule refuses it in a hand-written step.

    Args:
        line: One line, without its line break.

    Returns:
        The match, with the ``indent``, ``kind`` and ``id`` groups.
    """
    match: re.Match[str] | None = sync_inline_blocks.MARKER.match(line)
    return match


def yaml_files(repo: Path) -> Iterator[Path]:
    """Yield every workflow, example and composite action file, sorted.

    Args:
        repo: The repository root.

    Yields:
        Paths of ``.github/workflows/*.y*ml``, ``examples/*.y*ml`` and
        ``.github/actions/**/action.y*ml``.
    """
    for directory in (repo / ".github" / "workflows", repo / "examples"):
        yield from sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")])
    actions = repo / ".github" / "actions"
    yield from sorted([*actions.rglob("action.yml"), *actions.rglob("action.yaml")])


def block_bodies(repo: Path) -> dict[str, list[str]]:
    """Return the body the generator writes for each block, read from ``repo``.

    A block whose source cannot be read is left out, so any copy of it fails.

    Args:
        repo: The repository root.

    Returns:
        The bodies by block id.
    """
    bodies: dict[str, list[str]] = {}
    for block_id in sync_inline_blocks.BLOCKS:
        try:
            bodies[block_id] = sync_inline_blocks.generated_body(block_id, repo)
        except (OSError, sync_inline_blocks.MarkerError):
            continue
    # Written only into an egress-profile copy, without a header (#1688).
    for block_id in sync_inline_blocks.PROFILE_BLOCKS:
        try:
            bodies[block_id] = sync_inline_blocks.source_body(block_id, repo)
        except (OSError, sync_inline_blocks.MarkerError):
            continue
    return bodies


def scan_blocks(
    lines: list[str],
    bodies: dict[str, list[str]],
    skip: frozenset[int] = frozenset(),
) -> tuple[list[tuple[int, int]], list[BlockError]]:
    """Return the marker pairs of a text and what is wrong with them.

    Args:
        lines: The lines of a file (``str.splitlines``, as YAML splits
            it), or of the parsed text of one ``run:`` (``script_lines``,
            as bash splits it).
        bodies: The generated body per block id (:func:`block_bodies`).
        skip: Lines (1-based) to leave out: those of ``run:`` values, which
            are checked in their parsed form.

    Returns:
        ``(begin line, end line)`` per marker pair (1-based), and every broken
        marker and every copy that differs from its source, in file order.
    """
    ranges: list[tuple[int, int]] = []
    errors: list[BlockError] = []
    open_line, open_id, indent = 0, "", ""
    for number, line in enumerate(lines, start=1):
        match = None if number in skip else marker(line)
        if match is None:
            continue
        block_id = match["id"]
        known = (sync_inline_blocks.BLOCKS, sync_inline_blocks.PROFILE_BLOCKS)
        if not any(block_id in table for table in known):
            message = f"line {number}: unknown generated block id {block_id!r}"
            errors.append(BlockError(number, number, message))
        if match["kind"] == "begin":
            if open_id:
                message = f"line {number}: begin {block_id} inside {open_id}"
                errors.append(BlockError(number, number, message))
            open_line, open_id, indent = number, block_id, match["indent"]
        elif open_id != block_id:
            message = f"line {number}: end {block_id} without its begin"
            errors.append(BlockError(number, number, message))
        else:
            ranges.append((open_line, number))
            found = (lines[open_line : number - 1], indent)
            message = _body_problem(block_id, found, bodies)
            if message:
                message = f"line {open_line}: generated block {block_id} {message}"
                errors.append(BlockError(open_line, number, message))
            open_line, open_id = 0, ""
    if open_id:
        message = f"line {open_line}: begin {open_id} has no end"
        errors.append(BlockError(open_line, len(lines), message))
    return ranges, errors


def _body_problem(
    block_id: str,
    found: tuple[list[str], str],
    bodies: dict[str, list[str]],
) -> str:
    """Return what is wrong with the lines between one marker pair, else "".

    ``found`` is the lines and the indentation of the markers.
    """
    copy, indent = found
    if block_id not in bodies:
        return "has a source that cannot be read"
    expected = [f"{indent}{line}" if line else "" for line in bodies[block_id]]
    return "" if copy == expected else "differs from its source"


def run_lines(steps: list[Step]) -> frozenset[int]:
    """Return every file line (1-based) that lies in a ``run:`` value.

    Args:
        steps: The steps of one file.

    Returns:
        The lines; a block scalar's first line holds only ``run: |``.
    """
    lines: set[int] = set()
    for step in steps:
        first, last = step.run_lines
        lines.update(range(first, last + 1))
    return frozenset(lines)


def outside_markers(script: str) -> list[str]:
    """Return the code lines of a script outside its generated blocks.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        Every non-blank line before, between or after the marker pairs.
    """
    outside: list[str] = []
    inside = False
    for line in script_lines(script):
        match = marker(line)
        if match is not None:
            inside = match["kind"] == "begin"
        elif line.strip() and not inside:
            outside.append(line.strip())
    return outside


def _triggers(node: yaml.Node | None) -> set[str]:
    """Return the event names of a workflow's ``on:``, in any of its forms."""
    if isinstance(node, yaml.ScalarNode):
        return {str(node.value)}
    if isinstance(node, yaml.SequenceNode):
        items = node.value
        return {str(item.value) for item in items if isinstance(item, yaml.ScalarNode)}
    return set(mapping(node))


def _value_lines(node: yaml.Node) -> tuple[int, int]:
    """Return the first and last file line (1-based) of a value node."""
    first = node.start_mark.line + 1
    # A block scalar ends at column 0 of the line after its text.
    last = node.end_mark.line + (1 if node.end_mark.column else 0)
    return first, max(first, last)


def read_steps(text: str, relative: str) -> list[Step]:
    """Return the ``run:`` steps of one file.

    Args:
        text: The file contents.
        relative: The file's path relative to the repository root.

    Returns:
        The steps, each with its YAML context.

    Raises:
        yaml.YAMLError: When the file does not parse.
    """
    root = yaml.compose(text, Loader=yaml.SafeLoader)
    # Only a calling workflow sets the inputs of a workflow_call-only workflow.
    called = _triggers(mapping(root).get("on")) == {"workflow_call"}
    found: list[Step] = []
    for job_id, steps, scopes in step_groups(root):
        if not isinstance(steps, yaml.SequenceNode):
            continue
        action_dir = Path(relative).parent.as_posix() if job_id == COMPOSITE else None
        for index, node in enumerate(steps.value):
            fields = mapping(node)
            run = fields.get("run")
            if run is None:
                continue
            step = Step(
                relative,
                run.start_mark.line + 1,
                job_id,
                step_label(fields, index),
                "",
                (node.start_mark.line + 1, node.end_mark.line + 1),
                _value_lines(run),
                step_context(
                    node,
                    scopes,
                    action_dir,
                    caller=called or action_dir is not None,
                ),
            )
            if isinstance(run, yaml.ScalarNode) and run.tag == STR_TAG:
                step.run = str(run.value)
            else:
                step.fail(Rule.ALLOW_LIST, "run: is not a plain string")
            found.append(step)
    return found
