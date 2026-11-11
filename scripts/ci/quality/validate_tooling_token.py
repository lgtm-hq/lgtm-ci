#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check how reusable workflows handle the optional tooling token (#1451).

Usage: validate_tooling_token.py --workflows-dir DIR --actions-dir DIR
           [--allowlist FILE] [--ceiling N]

A private mirror of this repository needs a credential for the tooling
checkout, so a converted reusable takes the optional secret
``LGTM_CI_TOOLING_TOKEN`` and hands it to that checkout and to nothing else.

How the files are read. Every ``*.yml`` and ``*.yaml`` under the workflows
directory is parsed with PyYAML into a node tree, with aliases expanded, so a
step is seen the same way whether it is written in block style, flow style,
through an anchor, or with quoted or folded scalars. A file is checked when
its name starts with ``reusable-`` or it has ``on.workflow_call``. Every
mapping with a ``uses:`` key is classified, wherever it sits:

- tooling checkout: ``actions/checkout`` (any case) whose ``with.path``
  normalises to ``.lgtm-ci-tooling``;
- composite call: a ``uses:`` that ends in
  ``.github/actions/checkout-and-harden`` once a trailing slash and an
  ``@ref`` are dropped (local, tooling-relative and remote forms);
- nested call: a ``uses:`` that ends in ``.github/workflows/<file>``.

Fail-closed rule. What cannot be classified is an error, never "not tooling":

- a checkout whose ``path`` holds an expression is an error in every checked
  file, allowlisted or not, unless its last path component is a literal other
  than ``.lgtm-ci-tooling``, ``.`` or ``..`` (the path then cannot be the
  tooling directory itself). The same holds for a literal path that mentions
  ``.lgtm-ci-tooling`` without normalising to it;
- in a file that is not on the allowlist, ``.lgtm-ci-tooling`` as the
  ``with.path`` of a step that is not ``actions/checkout``, and
  ``checkout-and-harden`` in a ``uses:`` that is not a composite call, are
  errors;
- a file that does not parse, repeats a key, or uses a merge key (``<<``,
  which GitHub Actions does not support) is an error.

Each violation is printed as ``file:line: [rule] message``:

- ``token``: a tooling checkout must carry
  ``token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}`` and
  ``persist-credentials: false``.
- ``composite-call``: a composite call must pass
  ``tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}``.
- ``declaration``: a file that does either must declare the secret under
  ``on.workflow_call.secrets`` with ``required: false``.
- ``forward``: a nested call whose target declares the secret must forward it
  by name.
- ``unclassified``: the fail-closed rule above.
- ``yaml``: the file cannot be read as GitHub would read it.
- ``leak``: the secret name, in any letter case, may appear only as the
  declaration key and in the three values above. In a file that declares or
  names the secret, an expression may not read the ``secrets`` context as a
  whole or by index (``toJSON(secrets)``, ``secrets[...]``, ``secrets.*``),
  and no job may say ``secrets: inherit``. Expressions are the ``${{ }}``
  spans of every scalar and the whole of every ``if:``.
- ``composite``: in ``checkout-and-harden/action.yml`` only the tooling
  checkout's ``token:`` may read ``inputs.tooling-token``, in any letter case
  and by property or index; no expression may read ``inputs`` as a whole.
- ``allowlist``: the allowlist names the checked files that are not converted
  yet. A stale, duplicate, unsorted, tooling-free or already converted entry
  is an error, and the number of entries must equal the ceiling
  (``ALLOWLIST_CEILING`` below, or ``--ceiling``). A new entry therefore
  needs the ceiling raised in this file, and a removed one needs it lowered.

Allowlisted files are exempt from ``token``, ``composite-call``,
``declaration``, ``forward`` and the second ``unclassified`` item, and from
nothing else. A ``run:`` script that clones the tooling by hand is not seen.
"""

from __future__ import annotations

import argparse
import posixpath
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a bare interpreter
    sys.stderr.write(
        "ERROR: PyYAML is required (system python3 on GitHub-hosted runners, "
        "or this repository's dev extra locally)\n",
    )
    raise SystemExit(2) from None

SECRET = "LGTM_CI_TOOLING_TOKEN"  # nosec B105 - a secret's name, not its value
INPUT = "tooling-token"
TOOLING_PATH = ".lgtm-ci-tooling"
COMPOSITE = "checkout-and-harden"
TOKEN_EXPR = "${{ secrets." + SECRET + " || github.token }}"
FORWARD_EXPR = "${{ secrets." + SECRET + " }}"
COMPOSITE_TOKEN_EXPR = "${{ inputs." + INPUT + " || github.token }}"

# The number of allowlist entries. It only goes down: lower it in the pull
# request that converts a reusable and removes its entry.
ALLOWLIST_CEILING = 65

# Aliases are expanded into copies; this bounds a file built to explode.
NODE_BUDGET = 200_000

SCALAR = "scalar"
MAPPING = "mapping"
SEQUENCE = "sequence"

CHECKOUT = "checkout"
CHECKOUT_LIKE = "checkout-like"
COMPOSITE_CALL = "composite-call"
COMPOSITE_MENTION = "composite-mention"
NESTED = "nested"
OTHER = "other"

PATH_NONE = "none"
PATH_TOOLING = "tooling"
PATH_OTHER = "elsewhere"
PATH_UNKNOWN = "unknown"

COMPOSITE_REF = re.compile(r"(?:^|/)\.github/actions/" + COMPOSITE + "$")
WORKFLOW_REF = re.compile(r"(?:^|/)\.github/workflows/[^/]+\.ya?ml$")
EXPRESSION = re.compile(r"\$\{\{(.*?)(?:\}\}|\Z)", re.S)
STRING_LITERAL = re.compile(r"'(?:[^']|'')*'")
SECRET_NAME = re.compile(re.escape(SECRET), re.I)
INPUT_READ = re.compile(
    r"(?<![\w.-])inputs\s*\.\s*" + re.escape(INPUT) + r"(?![\w-])",
    re.I,
)


def whole_context(name: str) -> re.Pattern[str]:
    """Match a context that is not followed by ``.property``.

    Args:
        name: The context, ``secrets`` or ``inputs``.

    Returns:
        re.Pattern[str]: Matches ``toJSON(name)``, ``name[...]`` and
        ``name.*`` and leaves ``name.property`` and ``other.name`` alone.
    """
    return re.compile(
        r"(?<![\w.-])" + name + r"(?![\w-])(?!\s*\.\s*[A-Za-z_][\w-]*)",
        re.I,
    )


WHOLE_SECRETS = whole_context("secrets")
WHOLE_INPUTS = whole_context("inputs")


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


@dataclass(frozen=True, order=True)
class Finding:
    """One violation.

    Attributes:
        file: File name as printed to the reader.
        line: 1-based line number.
        rule: Rule slug from the module docstring.
        message: What is wrong and what is expected.
    """

    file: str
    line: int
    rule: str
    message: str

    def render(self) -> str:
        """Return the violation as ``file:line: [rule] message``."""
        return f"{self.file}:{self.line}: [{self.rule}] {self.message}"


@dataclass(frozen=True)
class Report:
    """What one checked workflow yields.

    Attributes:
        conversion: Violations of the rules an allowlisted file is exempt from.
        always: Violations of the rules that apply to every checked file.
        uses_tooling: Whether the file has anything the token applies to.
    """

    conversion: list[Finding]
    always: list[Finding]
    uses_tooling: bool


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


def build(source: yaml.Node, active: set[int], budget: list[int]) -> Node:
    """Copy a PyYAML node graph into a tree.

    An alias becomes a copy of its anchor's node, so each place a value is
    used has a node of its own.

    Args:
        source: The PyYAML node.
        active: Identities of the collections being built, to catch a cycle.
        budget: One-item list holding the number of nodes still allowed.

    Returns:
        Node: The copied node.

    Raises:
        Unreadable: On a recursive alias or too many nodes.
    """
    line = source.start_mark.line + 1
    budget[0] -= 1
    if budget[0] < 0:
        raise Unreadable(line, "too many nodes once aliases are expanded")
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
                (build(key, active, budget), build(value, active, budget))
                for key, value in source.value
            ],
        )
    else:
        node = Node(
            line=line,
            kind=SEQUENCE,
            items=[build(item, active, budget) for item in source.value],
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


def expressions(node: Node, key: str) -> Iterator[tuple[int, str]]:
    """Yield the GitHub expressions of a scalar, string literals blanked.

    Args:
        node: The scalar node.
        key: The mapping key the scalar is the value of.

    Yields:
        tuple[int, str]: Offset into ``node.text`` and the expression text,
        with each ``'...'`` literal replaced by spaces of the same length.
    """

    def blank(match: re.Match[str]) -> str:
        return " " * len(match.group())

    if key == "if":
        yield 0, STRING_LITERAL.sub(blank, node.text)
        return
    for match in EXPRESSION.finditer(node.text):
        yield match.start(1), STRING_LITERAL.sub(blank, match.group(1))


def classify_uses(text: str) -> tuple[str, str]:
    """Classify a ``uses:`` value.

    Args:
        text: The scalar value.

    Returns:
        tuple[str, str]: The kind and the target with ``@ref`` and trailing
        slashes dropped.
    """
    target = text.strip().split("@", 1)[0].rstrip("/")
    lowered = target.lower()
    if lowered == "actions/checkout":
        return CHECKOUT, target
    if COMPOSITE_REF.search(lowered):
        return COMPOSITE_CALL, target
    if COMPOSITE in text.lower():
        return COMPOSITE_MENTION, target
    if WORKFLOW_REF.search(lowered):
        return NESTED, target
    if lowered.rsplit("/", 1)[-1] == "checkout":
        return CHECKOUT_LIKE, target
    return OTHER, target


def classify_path(node: Node | None) -> str:
    """Tell where a step's ``with.path`` points.

    Args:
        node: The ``path`` value node, or None when the key is absent.

    Returns:
        str: ``none`` (no path), ``tooling``, ``elsewhere`` (provably not the
        tooling directory) or ``unknown``.
    """
    if node is None:
        return PATH_NONE
    if node.kind != SCALAR:
        return PATH_UNKNOWN
    value = node.text.strip().replace("\\", "/").lower()
    if not value:
        return PATH_NONE
    if "${{" not in value:
        if posixpath.normpath(value) == TOOLING_PATH:
            return PATH_TOOLING
        return PATH_UNKNOWN if TOOLING_PATH in value else PATH_OTHER
    last = EXPRESSION.sub("\0", value).rstrip("/").rsplit("/", 1)[-1]
    if "\0" in last or last in ("", ".", "..") or TOOLING_PATH in last:
        return PATH_UNKNOWN
    return PATH_OTHER


def secret_declaration(root: Node | None) -> tuple[Node | None, bool]:
    """Find the secret under ``on.workflow_call.secrets``.

    Args:
        root: Root node of a workflow.

    Returns:
        tuple[Node | None, bool]: The declaration's key node (None when the
        secret is not declared) and whether it says ``required: false``.
    """
    entry = fields(descend(root, "on", "workflow_call", "secrets")).get(SECRET)
    if entry is None:
        return None, False
    required = descend(entry[1], "required")
    if required is None or required.kind != SCALAR or required.style:
        return entry[0], False
    return entry[0], required.text == "false"


def is_reusable(root: Node | None) -> bool:
    """Tell whether a workflow can be called (``on.workflow_call``).

    Args:
        root: Root node of a workflow.

    Returns:
        bool: True for ``on: workflow_call``, a list that names it, or a
        mapping with that key.
    """
    trigger = descend(root, "on")
    if trigger is None:
        return False
    names = [trigger.text] if trigger.kind == SCALAR else list(fields(trigger))
    names += [item.text for item in trigger.items if item.kind == SCALAR]
    return "workflow_call" in names


def declares(path: Path) -> bool | None:
    """Tell whether a workflow file declares the secret.

    Args:
        path: The workflow file.

    Returns:
        bool | None: None when the file does not exist.
    """
    if not path.is_file():
        return None
    return secret_declaration(parse(path.read_text())[0])[0] is not None


class Check:
    """Collects the violations of one file.

    Args:
        path: The file, read and parsed on construction.
        label: The file name to print; the file's own name when empty.
    """

    def __init__(self, path: Path, label: str = "") -> None:
        self.path = path
        self.name = label or path.name
        self.root, self.problems = parse(path.read_text())
        self.findings: list[Finding] = []
        self.always: list[Finding] = []
        self.allowed: set[int] = set()

    def fail(self, line: int, rule: str, message: str, *, always: bool = False) -> None:
        """Record a violation.

        Args:
            line: 1-based line number.
            rule: Rule slug.
            message: What is wrong and what is expected.
            always: Whether the rule also applies to an allowlisted file.
        """
        finding = Finding(file=self.name, line=line, rule=rule, message=message)
        (self.always if always else self.findings).append(finding)

    def expect(
        self,
        *,
        keys: dict[str, tuple[Node, Node]],
        name: str,
        expected: str,
        anchor: Node,
        rule: str,
        subject: str = "",
    ) -> None:
        """Require ``name: expected`` among ``keys``.

        Args:
            keys: The entries of a ``with:`` or ``secrets:`` mapping.
            name: The key that must be present.
            expected: The exact value it must have.
            anchor: The node to report when the key is missing.
            rule: Rule slug for the violation.
            subject: Words to put before ``missing``.
        """
        if name not in keys:
            lead = f"{subject} is missing" if subject else "missing"
            self.fail(anchor.line, rule, f"{lead} `{name}: {expected}`")
            return
        value = keys[name][1]
        if value.kind != SCALAR or value.text != expected:
            found = value.text if value.kind == SCALAR else f"a {value.kind}"
            self.fail(
                value.line,
                rule,
                f"`{name}` must be exactly `{expected}`, found `{found}`",
            )

    def allow(self, keys: dict[str, tuple[Node, Node]], name: str) -> None:
        """Let the value of ``keys[name]`` name the secret or the input.

        Args:
            keys: The entries of a mapping.
            name: The key whose value is one of the permitted places.
        """
        if name in keys:
            self.allowed.add(id(keys[name][1]))

    def steps(self) -> Iterator[tuple[dict[str, tuple[Node, Node]], Node, str, str]]:
        """Yield every mapping that has a scalar ``uses:``, in file order.

        Yields:
            tuple: The mapping's entries, the ``uses`` value node, its kind
            and its target (see :func:`classify_uses`).
        """
        for node, _ in walk(self.root) if self.root else []:
            keys = fields(node)
            if "uses" in keys and keys["uses"][1].kind == SCALAR:
                uses = keys["uses"][1]
                yield keys, uses, *classify_uses(uses.text)

    def step_inputs(
        self,
        keys: dict[str, tuple[Node, Node]],
        uses: Node,
        rule: str,
    ) -> dict[str, tuple[Node, Node]]:
        """Return a step's ``with:`` entries.

        Args:
            keys: The step's entries.
            uses: The step's ``uses`` value node.
            rule: Rule slug for a ``with:`` that is not a mapping.

        Returns:
            dict[str, tuple[Node, Node]]: The inputs by name.
        """
        given = keys.get("with")
        empty = given is not None and (given[1].kind, given[1].text) == (SCALAR, "")
        if given and given[1].kind != MAPPING and not empty:
            message = f"`with` of `{uses.text}` is not a mapping"
            self.fail(
                given[1].line,
                rule,
                f"{message}, so its inputs cannot be checked",
                always=True,
            )
        return fields(given[1]) if given else {}

    def checkout_path(
        self,
        inputs: dict[str, tuple[Node, Node]],
        uses: Node,
        rule: str,
    ) -> str:
        """Classify a checkout's ``path`` and report one that cannot be.

        Args:
            inputs: The step's ``with:`` entries.
            uses: The step's ``uses`` value node.
            rule: Rule slug for a path that cannot be classified.

        Returns:
            str: The path kind (see :func:`classify_path`).
        """
        path = inputs["path"][1] if "path" in inputs else None
        kind = classify_path(path)
        if kind == PATH_UNKNOWN and path is not None:
            shown = path.text if path.kind == SCALAR else f"a {path.kind}"
            self.fail(
                path.line,
                rule,
                f"checkout `path: {shown}` cannot be told apart from "
                f"{TOOLING_PATH}; write the path so that its last component is "
                "a literal",
                always=True,
            )
        return kind


class WorkflowCheck(Check):
    """Collects the violations of one reusable workflow.

    Args:
        path: The reusable workflow file, read and parsed on construction.
    """

    def __init__(self, path: Path) -> None:
        super().__init__(path)
        self.first_use: int | None = None
        self.inherits: list[tuple[Node, str]] = []

    def check_nested(
        self,
        uses: Node,
        target: str,
        keys: dict[str, tuple[Node, Node]],
    ) -> bool:
        """Apply the ``forward`` rule to one nested reusable call.

        Args:
            uses: The job's ``uses`` value node.
            target: The called workflow, without ``@ref``.
            keys: The job's entries.

        Returns:
            bool: Whether the call takes, or should take, the secret.
        """
        name = target.rsplit("/", 1)[-1]
        declared = declares(self.path.parent / name)
        given = keys["secrets"][1] if "secrets" in keys else None
        if given and given.kind == SCALAR and given.text.strip().lower() == "inherit":
            self.inherits.append((given, name))
            return bool(declared)
        forwarded = fields(given)
        if SECRET in forwarded:
            self.allowed.update(id(node) for node in forwarded[SECRET])
            if declared is False:
                self.fail(
                    forwarded[SECRET][0].line,
                    "forward",
                    f"forwards {SECRET} to {name}, which does not declare it",
                )
                return True
        elif not declared:
            return False
        self.expect(
            keys=forwarded,
            name=SECRET,
            expected=FORWARD_EXPR,
            anchor=uses,
            rule="forward",
        )
        return True

    def check_step(
        self,
        keys: dict[str, tuple[Node, Node]],
        uses: Node,
        kind: str,
        target: str,
    ) -> bool:
        """Apply the rules to one ``uses:``.

        Args:
            keys: The entries of the step or job.
            uses: The ``uses`` value node.
            kind: The kind from :func:`classify_uses`.
            target: The target from :func:`classify_uses`.

        Returns:
            bool: Whether this is a place the tooling token applies to.
        """
        if kind == NESTED:
            return self.check_nested(uses, target, keys)
        if kind == COMPOSITE_MENTION:
            self.fail(
                uses.line,
                "unclassified",
                f"`uses: {uses.text}` names {COMPOSITE} but is not a call of "
                f".github/actions/{COMPOSITE}",
            )
            return True
        inputs = self.step_inputs(keys, uses, "unclassified")
        if kind == COMPOSITE_CALL:
            self.allow(inputs, INPUT)
            self.expect(
                keys=inputs,
                name=INPUT,
                expected=FORWARD_EXPR,
                anchor=uses,
                rule="composite-call",
            )
            return True
        if kind == OTHER:
            where = classify_path(inputs["path"][1] if "path" in inputs else None)
        else:
            where = self.checkout_path(inputs, uses, "unclassified")
        if where == PATH_UNKNOWN and kind != OTHER:
            return True
        if where != PATH_TOOLING:
            return False
        if kind != CHECKOUT:
            self.fail(
                uses.line,
                "unclassified",
                f"`uses: {uses.text}` writes to {TOOLING_PATH} but is not "
                "actions/checkout, so its token cannot be checked",
            )
            return True
        self.allow(inputs, "token")
        for name, expected in (("token", TOKEN_EXPR), ("persist-credentials", "false")):
            self.expect(
                keys=inputs,
                name=name,
                expected=expected,
                anchor=uses,
                rule="token",
            )
        return True

    def check_declaration(self) -> None:
        """Apply the ``declaration`` rule once every use is known."""
        key, optional = secret_declaration(self.root)
        if key is not None:
            self.allowed.add(id(key))
            if not optional:
                self.fail(
                    key.line,
                    "declaration",
                    f"secret {SECRET} must be declared with `required: false`",
                )
        elif self.first_use is not None:
            self.fail(
                self.first_use,
                "declaration",
                f"uses the tooling token but does not declare secret {SECRET} "
                "under on.workflow_call.secrets with `required: false`",
            )

    def check_leaks(self) -> None:
        """Apply the ``leak`` rule to every scalar of the file."""
        scalars = [
            (node, key)
            for node, key in (walk(self.root) if self.root else [])
            if node.kind == SCALAR
        ]
        named = any(SECRET_NAME.search(node.text) for node, _ in scalars)
        for node, key in scalars:
            if id(node) in self.allowed:
                continue
            for match in SECRET_NAME.finditer(node.text):
                self.fail(
                    line_at(node, match.start()),
                    "leak",
                    f"{SECRET} may only be declared, passed to the tooling "
                    f"checkout's `token`, to {COMPOSITE}'s `{INPUT}` and to a "
                    "nested reusable's `secrets`",
                    always=True,
                )
            if not named:
                continue
            for offset, expression in expressions(node, key):
                for match in WHOLE_SECRETS.finditer(expression):
                    self.fail(
                        line_at(node, offset + match.start()),
                        "leak",
                        "the expression reads the secrets context as a whole or "
                        f"by index, which can expose {SECRET}; read each secret "
                        "as `secrets.NAME`",
                        always=True,
                    )
        for node, target in self.inherits:
            if named:
                self.fail(
                    node.line,
                    "leak",
                    f"`secrets: inherit` hands every secret, {SECRET} included, "
                    f"to {target}; forward secrets by name",
                    always=True,
                )
            elif declares(self.path.parent / target):
                self.fail(
                    node.line,
                    "forward",
                    f"`secrets: inherit` is not accepted; forward {SECRET} to {target}",
                )

    def run(self) -> Report:
        """Check the whole workflow.

        Returns:
            Report: The violations, split by whether the allowlist exempts
            them, and whether the file uses the tooling at all.
        """
        for line, message in self.problems:
            self.fail(line, "yaml", message, always=True)
        for keys, uses, kind, target in self.steps():
            if self.check_step(keys, uses, kind, target) and self.first_use is None:
                self.first_use = uses.line
        self.check_declaration()
        self.check_leaks()
        return Report(
            conversion=self.findings,
            always=self.always,
            uses_tooling=self.first_use is not None,
        )


class CompositeCheck(Check):
    """Collects the violations of ``checkout-and-harden/action.yml``.

    Args:
        path: The composite's ``action.yml``.
    """

    def __init__(self, path: Path) -> None:
        super().__init__(path, f"{COMPOSITE}/{path.name}")

    def broken(self, line: int, message: str) -> None:
        """Record a violation of the ``composite`` rule.

        Args:
            line: 1-based line number.
            message: What is wrong and what is expected.
        """
        self.fail(line, "composite", message, always=True)

    def check_reads(self) -> None:
        """Let only the permitted ``token:`` read the token input."""
        for node, key in walk(self.root) if self.root else []:
            if node.kind != SCALAR or id(node) in self.allowed:
                continue
            offsets = [match.start() for match in INPUT_READ.finditer(node.text)]
            offsets += [
                offset + match.start()
                for offset, expression in expressions(node, key)
                for match in WHOLE_INPUTS.finditer(expression)
            ]
            for offset in offsets:
                self.broken(
                    line_at(node, offset),
                    f"only the tooling checkout's `token:` may read inputs.{INPUT}",
                )

    def run(self) -> list[Finding]:
        """Check the whole composite.

        Returns:
            list[Finding]: The violations found.
        """
        for line, message in self.problems:
            self.broken(line, message)
        declared = fields(self.root).get("inputs")
        if declared is None or INPUT not in fields(declared[1]):
            line = declared[0].line if declared else 1
            self.broken(line, f"input `{INPUT}` is not declared")
        checkouts = 0
        for keys, uses, kind, _ in self.steps():
            if kind not in (CHECKOUT, CHECKOUT_LIKE):
                continue
            inputs = self.step_inputs(keys, uses, "composite")
            if self.checkout_path(inputs, uses, "composite") != PATH_TOOLING:
                continue
            if kind != CHECKOUT:
                self.broken(
                    uses.line,
                    f"`uses: {uses.text}` is not actions/checkout but writes to "
                    f"the tooling directory {TOOLING_PATH}, which only it may do",
                )
                continue
            checkouts += 1
            self.allow(inputs, "token")
            for name, expected in (
                ("token", COMPOSITE_TOKEN_EXPR),
                ("persist-credentials", "false"),
            ):
                self.expect(
                    keys=inputs,
                    name=name,
                    expected=expected,
                    anchor=uses,
                    rule="composite",
                    subject="tooling checkout",
                )
        if not checkouts:
            self.broken(1, f"no checkout with `path: {TOOLING_PATH}` found")
        self.check_reads()
        return self.always + self.findings


def check_composite(action: Path) -> list[Finding]:
    """Apply the ``composite`` rule to ``checkout-and-harden/action.yml``.

    Args:
        action: The composite's ``action.yml``.

    Returns:
        list[Finding]: The violations found.
    """
    if not action.is_file():
        name = f"{COMPOSITE}/{action.name}"
        return [Finding(file=name, line=1, rule="composite", message="file not found")]
    return CompositeCheck(action).run()


def read_allowlist(path: Path | None) -> tuple[dict[str, int], list[Finding]]:
    """Read the allowlist of reusables that are not converted yet.

    Args:
        path: The allowlist file, or None when there is none.

    Returns:
        tuple[dict[str, int], list[Finding]]: Entry to its line number, and
        the violations of the file's own format (order, duplicates).
    """
    entries: dict[str, int] = {}
    findings: list[Finding] = []
    if path is None:
        return entries, findings
    previous = ""
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        if entry in entries:
            message = f"duplicate entry {entry}"
        elif entry < previous:
            message = f"entries must be sorted; {entry} follows {previous}"
        else:
            message = ""
        if message:
            findings.append(
                Finding(file=path.name, line=number, rule="allowlist", message=message),
            )
        entries.setdefault(entry, number)
        previous = entry
    return entries, findings


def check_ceiling(listed: str, count: int, ceiling: int) -> list[Finding]:
    """Require the allowlist to be exactly as long as the ceiling.

    Args:
        listed: The allowlist's file name as printed to the reader.
        count: The number of distinct entries.
        ceiling: The committed maximum.

    Returns:
        list[Finding]: One violation when the two differ.
    """
    if count > ceiling:
        message = (
            f"{count} entries, above the ceiling of {ceiling}: the list only "
            "shrinks, so convert the reusable instead of listing it"
        )
    elif count < ceiling:
        message = (
            f"{count} entries, below the ceiling of {ceiling}: lower "
            f"ALLOWLIST_CEILING in {Path(__file__).name} to {count}"
        )
    else:
        return []
    name = listed or "allowlist"
    return [Finding(file=name, line=1, rule="allowlist", message=message)]


def validate(
    *,
    workflows_dir: Path,
    actions_dir: Path,
    allowlist: Path | None,
    ceiling: int | None = None,
) -> tuple[list[Finding], int, int]:
    """Check every reusable workflow and the composite.

    Args:
        workflows_dir: Directory holding the workflow files.
        actions_dir: Directory holding the composite actions.
        allowlist: File naming the reusables not converted yet, or None.
        ceiling: The number of entries the allowlist must have; None skips
            the comparison.

    Returns:
        tuple[list[Finding], int, int]: The violations, the number of
        converted reusables and the number of allowlisted ones.
    """
    entries, findings = read_allowlist(allowlist)
    listed = allowlist.name if allowlist else ""
    if ceiling is not None:
        findings += check_ceiling(listed, len(entries), ceiling)
    findings += check_composite(actions_dir / COMPOSITE / "action.yml")
    converted = 0
    seen: set[str] = set()
    files = [*workflows_dir.glob("*.yml"), *workflows_dir.glob("*.yaml")]
    for workflow in sorted(files):
        check = WorkflowCheck(workflow)
        named = workflow.name.startswith("reusable-")
        if not named and not is_reusable(check.root):
            continue
        report = check.run()
        findings += report.always
        seen.add(workflow.name)
        if workflow.name not in entries:
            findings += report.conversion
            converted += report.uses_tooling
        elif not report.conversion:
            state = "is already converted" if report.uses_tooling else "has no tooling"
            findings.append(
                Finding(
                    file=listed,
                    line=entries[workflow.name],
                    rule="allowlist",
                    message=f"{workflow.name} {state}; remove the entry",
                ),
            )
    findings += [
        Finding(
            file=listed,
            line=number,
            rule="allowlist",
            message=f"{entry} does not exist in {workflows_dir.name}; remove the entry",
        )
        for entry, number in entries.items()
        if entry not in seen
    ]
    return sorted(set(findings)), converted, len(entries)


def main(argv: list[str] | None = None) -> int:
    """Run the check from the command line.

    Args:
        argv: Arguments after the program name; ``sys.argv`` when None.

    Returns:
        int: 0 when the contract holds, 1 on a violation, 2 on a bad path.
    """
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--workflows-dir", type=Path, required=True)
    parser.add_argument("--actions-dir", type=Path, required=True)
    parser.add_argument("--allowlist", type=Path, default=None)
    parser.add_argument("--ceiling", type=int, default=ALLOWLIST_CEILING)
    args = parser.parse_args(argv)
    for label, directory in (
        ("workflows", args.workflows_dir),
        ("actions", args.actions_dir),
    ):
        if not directory.is_dir():
            print(f"ERROR: {label} directory not found: {directory}", file=sys.stderr)
            return 2
    if args.allowlist is not None and not args.allowlist.is_file():
        print(f"ERROR: allowlist not found: {args.allowlist}", file=sys.stderr)
        return 2
    findings, converted, allowlisted = validate(
        workflows_dir=args.workflows_dir,
        actions_dir=args.actions_dir,
        allowlist=args.allowlist,
        ceiling=args.ceiling,
    )
    if findings:
        print("ERROR: tooling token contract violations:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding.render()}", file=sys.stderr)
        return 1
    print(
        f"OK: tooling token contract satisfied ({converted} converted, "
        f"{allowlisted} allowlisted)",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
