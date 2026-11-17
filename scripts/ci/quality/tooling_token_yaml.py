#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read workflow YAML the way the tooling token check needs it (#1451, #1622).

Shared by ``validate_tooling_token.py`` and ``tooling_app_credential.py``.
Every file is parsed with PyYAML into a tree of :class:`Node`, aliases
expanded into copies, so a value is seen the same way whether it is written in
block style, flow style, through an anchor, or as a quoted or folded scalar.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path

import yaml

TOOLING_PATH = ".lgtm-ci-tooling"
# The one repository a tooling checkout may name in a reusable: the repository
# the running workflow came from.
WORKFLOW_REPOSITORY = "${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}"

# Aliases are expanded into copies; this bounds a file built to explode.
NODE_BUDGET = 200_000

# Deeper nesting than any workflow needs; it also keeps the recursive walks
# of this file far from the interpreter's recursion limit.
MAX_DEPTH = 64

SCALAR = "scalar"
MAPPING = "mapping"
SEQUENCE = "sequence"


@dataclass(eq=False)
class Node:
    """One node of a parsed YAML file, with aliases expanded into copies.

    Attributes:
        line: 1-based line the node starts on.
        kind: ``scalar``, ``mapping`` or ``sequence``.
        text: A scalar's value; empty for the other kinds.
        style: A scalar's style indicator (``|``, ``>``, a quote) or empty.
        pairs: A mapping's key and value nodes, in file order.
        items: A sequence's nodes, in file order.
    """

    line: int
    kind: str
    text: str = ""
    style: str = ""
    pairs: list[tuple[Node, Node]] = field(default_factory=list)
    items: list[Node] = field(default_factory=list)


class Unreadable(Exception):
    """A file that cannot be read as GitHub would read it.

    Args:
        line: 1-based line the problem is on.
        message: What the problem is.
    """

    def __init__(self, line: int, message: str) -> None:
        super().__init__(message)
        self.line = line
        self.message = message


def build(
    source: yaml.Node,
    active: set[int],
    budget: list[int],
    depth: int = 0,
) -> Node:
    """Copy a PyYAML node graph into a tree.

    An alias becomes a copy of its anchor's node, so each place a value is
    used has a node of its own.

    Args:
        source: The PyYAML node.
        active: Identities of the collections being built, to catch a cycle.
        budget: One-item list holding the number of nodes still allowed.
        depth: How many collections enclose ``source``.

    Returns:
        Node: The copied node.

    Raises:
        Unreadable: On a recursive alias, too many nodes or too deep nesting.
    """
    line = source.start_mark.line + 1
    budget[0] -= 1
    if budget[0] < 0:
        raise Unreadable(line, "too many nodes once aliases are expanded")
    if depth > MAX_DEPTH:
        raise Unreadable(line, f"nested more than {MAX_DEPTH} levels deep")
    if isinstance(source, yaml.ScalarNode):
        return Node(line=line, kind=SCALAR, text=source.value, style=source.style or "")
    if id(source) in active:
        raise Unreadable(line, "an alias refers to its own anchor")
    active.add(id(source))
    if isinstance(source, yaml.MappingNode):
        node = Node(
            line=line,
            kind=MAPPING,
            pairs=[
                (
                    build(key, active, budget, depth + 1),
                    build(value, active, budget, depth + 1),
                )
                for key, value in source.value
            ],
        )
    else:
        node = Node(
            line=line,
            kind=SEQUENCE,
            items=[build(item, active, budget, depth + 1) for item in source.value],
        )
    active.discard(id(source))
    return node


def walk(node: Node, key: str = "") -> Iterator[tuple[Node, str]]:
    """Yield every node below and including ``node``, in file order.

    Args:
        node: Where to start.
        key: The mapping key ``node`` is the value of, if any.

    Yields:
        tuple[Node, str]: A node and the key it is the value of; a key node,
        a sequence item and the root come with an empty string.
    """
    yield node, key
    for name, value in node.pairs:
        yield name, ""
        yield from walk(value, name.text if name.kind == SCALAR else "")
    for item in node.items:
        yield from walk(item)


def fields(node: Node | None) -> dict[str, tuple[Node, Node]]:
    """Return a mapping's entries by key.

    Args:
        node: Any node, or None.

    Returns:
        dict[str, tuple[Node, Node]]: Key text to its key and value nodes;
        empty when ``node`` is not a mapping. The first of a repeated key wins
        (a repeated key is reported by :func:`parse`).
    """
    found: dict[str, tuple[Node, Node]] = {}
    for key, value in node.pairs if node else []:
        if key.kind == SCALAR:
            found.setdefault(key.text, (key, value))
    return found


def descend(node: Node | None, *names: str) -> Node | None:
    """Follow a chain of mapping keys.

    Args:
        node: The mapping to start from.
        *names: The keys to follow, outermost first.

    Returns:
        Node | None: The value reached, or None when a key is missing.
    """
    for name in names:
        entry = fields(node).get(name)
        if entry is None:
            return None
        node = entry[1]
    return node


def parse(text: str) -> tuple[Node | None, list[tuple[int, str]]]:
    """Parse one YAML file.

    Args:
        text: The file content.

    Returns:
        tuple[Node | None, list[tuple[int, str]]]: The root node (None for an
        empty or unreadable file) and the problems as line and message.
    """
    loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
    try:
        source = yaml.compose(text, Loader=loader)  # nosec B506 - no objects built
        root = build(source, set(), [NODE_BUDGET]) if source is not None else None
    except Unreadable as error:
        return None, [(error.line, error.message)]
    except RecursionError:
        return None, [(1, "not valid YAML: nested too deeply to be parsed")]
    except yaml.YAMLError as error:
        mark = getattr(error, "problem_mark", None)
        problem = getattr(error, "problem", None) or "cannot be parsed"
        return None, [(mark.line + 1 if mark else 1, f"not valid YAML: {problem}")]
    problems: list[tuple[int, str]] = []
    for node, _ in walk(root) if root else []:
        seen: set[str] = set()
        for key, _ in node.pairs:
            if key.kind != SCALAR:
                continue
            if key.text == "<<" and not key.style:
                problems.append(
                    (key.line, "merge keys (`<<`) are not read by GitHub Actions"),
                )
            if key.text in seen:
                problems.append((key.line, f"key `{key.text}` is repeated"))
            seen.add(key.text)
    return root, problems


def line_at(node: Node, offset: int) -> int:
    """Return the line of a character of a scalar.

    Exact for plain, quoted and literal (``|``) scalars; a folded scalar
    (``>``) reports a line at or before the real one.

    Args:
        node: The scalar node.
        offset: Index into ``node.text``.

    Returns:
        int: 1-based line number.
    """
    header = 1 if node.style in ("|", ">") else 0
    return node.line + header + node.text.count("\n", 0, offset)


def is_expression(node: Node, key: str) -> bool:
    """Tell whether GitHub evaluates a scalar as, or with, an expression.

    Args:
        node: The scalar node.
        key: The mapping key the scalar is the value of.

    Returns:
        bool: True for a scalar that holds ``${{`` and for every ``if:``.
    """
    return key == "if" or "${{" in node.text


def loose_reads(text: str, word: re.Pattern[str], member: re.Pattern[str]) -> list[int]:
    """Find the places a scalar reads a context other than by one name.

    The scalar is searched as a whole. Nothing tells a string literal from
    code or one expression from the next, so nothing can be hidden behind a
    quote or a ``}}``.

    Args:
        text: The scalar value.
        word: Matches the context name.
        member: Matches what has to follow it.

    Returns:
        list[int]: Offset of each context name not followed by ``member``.
    """
    words = word.finditer(text)
    return [at.start() for at in words if not member.match(text, at.end())]


def load(path: Path) -> tuple[Node | None, list[tuple[int, str]]]:
    """Read and parse one YAML file.

    Args:
        path: The file.

    Returns:
        tuple[Node | None, list[tuple[int, str]]]: As :func:`parse`; a file
        that cannot be read as UTF-8 text is one more problem.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        return None, [(1, f"cannot be read: {error}")]
    return parse(text)
