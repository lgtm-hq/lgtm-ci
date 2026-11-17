#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared rules of the tooling token check (#1451, #1622).

Constants, the ``uses:`` and ``path`` classifiers and the :class:`Check` base
class used by ``validate_tooling_token.py`` for workflows and composites. See
that file's docstring for the rules themselves.
"""

from __future__ import annotations

import posixpath
import re
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

from tooling_token_yaml import (
    MAPPING,
    SCALAR,
    TOOLING_PATH,
    WORKFLOW_REPOSITORY,
    Node,
    descend,
    fields,
    load,
    walk,
)

SECRET = "LGTM_CI_TOOLING_TOKEN"  # nosec B105 - a secret's name, not its value
INPUT = "tooling-token"
COMPOSITE = "checkout-and-harden"
TOKEN_EXPR = "${{ secrets." + SECRET + " || github.token }}"
FORWARD_EXPR = "${{ secrets." + SECRET + " }}"
COMPOSITE_TOKEN_EXPR = "${{ inputs." + INPUT + " || github.token }}"
# The only inputs a tooling checkout may set. Anything else, such as
# `github-server-url` or `ssh-key`, could change where the token is sent.
CHECKOUT_INPUTS = frozenset(
    {
        "path",
        "persist-credentials",
        "ref",
        "repository",
        "sparse-checkout",
        "sparse-checkout-cone-mode",
        "token",
    },
)
# The one repository a tooling checkout may name: in a reusable,
# WORKFLOW_REPOSITORY (the repository the running workflow came from); in the
# composite, its input.
COMPOSITE_REPOSITORY = "${{ inputs.tooling-repository }}"
# A checkout into any other directory that names one of these repositories
# reads the tooling repository too, so it is a tooling checkout as well.
SELF_REPOSITORIES = frozenset(
    {WORKFLOW_REPOSITORY, "${{ job.workflow_repository }}"},
)
# Actions that hand their `path` to actions/checkout.
CHECKOUT_ACTIONS = frozenset({"checkout", "secure-checkout"})
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

STAGED_COMPOSITE = re.compile(
    r"\./" + re.escape(TOOLING_PATH) + r"/\.github/actions/" + COMPOSITE + "/?",
)
WORKFLOW_REF = re.compile(r"(?:^|/)\.github/workflows/[^/]+\.ya?ml$")
LOCAL_WORKFLOW = re.compile(r"\./\.github/workflows/([^/@]+\.ya?ml)")
EXPRESSION = re.compile(r"\$\{\{(.*?)(?:\}\}|\Z)", re.S)
SECRET_NAME = re.compile(re.escape(SECRET), re.I)
INPUT_NAME = re.compile(re.escape(INPUT), re.I)
ANYTHING = re.compile("")
PASS_THROUGH_PATH = "${{ inputs.path }}"  # nosec B105 - an expression

# A context name where an expression would read it: not a property of another
# object (`inputs.secrets`) and not part of a longer word (`my-secrets`).
SECRETS_WORD = re.compile(r"(?<![\w.-])secrets(?![\w-])", re.I)
INPUTS_WORD = re.compile(r"(?<![\w.-])inputs(?![\w-])", re.I)
# What may follow the context name: one property, by name.
PROPERTY = re.compile(r"\s*\.\s*[A-Za-z_][\w-]*")
PROPERTY_OR_INDEX = re.compile(
    r"\s*\.\s*[A-Za-z_][\w-]*|\s*\[\s*'[A-Za-z_][\w-]*'\s*\]",
)


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


def classify_uses(text: str) -> tuple[str, str]:
    """Classify a ``uses:`` value.

    Args:
        text: The scalar value.

    Returns:
        tuple[str, str]: The kind and the target with ``@ref`` and trailing
        slashes dropped.
    """
    stripped = text.strip()
    target = stripped.split("@", 1)[0].rstrip("/")
    lowered = target.lower()
    if lowered == "actions/checkout":
        return CHECKOUT, target
    if STAGED_COMPOSITE.fullmatch(stripped):
        return COMPOSITE_CALL, target
    if COMPOSITE in stripped.lower():
        return COMPOSITE_MENTION, target
    if WORKFLOW_REF.search(lowered):
        return NESTED, target
    if lowered.rsplit("/", 1)[-1] in CHECKOUT_ACTIONS:
        return CHECKOUT_LIKE, target
    return OTHER, target


def classify_path(node: Node | None) -> str:  # pylint: disable=too-many-return-statements
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
        mapping with that key. Every ``on`` key counts, so a repeated one
        cannot hide the trigger.
    """
    for key, trigger in root.pairs if root else []:
        if key.kind != SCALAR or key.text != "on":
            continue
        names = [trigger.text] if trigger.kind == SCALAR else list(fields(trigger))
        names += [item.text for item in trigger.items if item.kind == SCALAR]
        if "workflow_call" in names:
            return True
    return False


def declares(path: Path) -> bool | None:
    """Tell whether a workflow file declares the secret.

    Args:
        path: The workflow file.

    Returns:
        bool | None: None when the file does not exist.
    """
    if not path.is_file():
        return None
    return secret_declaration(load(path)[0])[0] is not None


class Check:
    """Collects the violations of one file.

    Args:
        path: The file, read and parsed on construction.
        label: The file name to print; the file's own name when empty.
    """

    def __init__(self, path: Path, label: str = "") -> None:
        self.path = path
        self.name = label or path.name
        self.root, self.problems = load(path)
        self.findings: list[Finding] = []
        self.settled: set[int] = set()

    def scalars(self) -> list[tuple[Node, str]]:
        """Return every scalar of the file, keys included, with its key."""
        found = walk(self.root) if self.root else []
        return [(node, key) for node, key in found if node.kind == SCALAR]

    def fail(self, line: int, rule: str, message: str) -> None:
        """Record a violation.

        Args:
            line: 1-based line number.
            rule: Rule slug.
            message: What is wrong and what is expected.
        """
        self.findings.append(
            Finding(file=self.name, line=line, rule=rule, message=message),
        )

    def expect(  # pylint: disable=too-many-arguments
        self,
        *,
        keys: dict[str, tuple[Node, Node]],
        name: str,
        expected: str,
        anchor: Node,
        rule: str,
        subject: str = "",
        guard: re.Pattern[str] | None = None,
    ) -> None:
        """Require ``name: expected`` among ``keys``.

        With ``guard``, this is one of the places a guarded word may appear.
        A value that holds the guarded word is settled, so the search for
        stray uses skips it: it is either exactly ``expected`` or its mismatch
        is reported here.

        Args:
            keys: The entries of a ``with:`` or ``secrets:`` mapping.
            name: The key that must be present.
            expected: The exact value it must have.
            anchor: The node to report when the key is missing.
            rule: Rule slug for the violation.
            subject: Words to put before ``missing``.
            guard: Matches the word whose uses this place may hold.
        """
        if name not in keys:
            lead = f"{subject} is missing" if subject else "missing"
            self.fail(anchor.line, rule, f"{lead} `{name}: {expected}`")
            return
        value = keys[name][1]
        if guard and value.kind == SCALAR and guard.search(value.text):
            self.settled.add(id(value))
        if value.kind == SCALAR and value.text == expected:
            return
        found = value.text if value.kind == SCALAR else f"a {value.kind}"
        self.fail(
            value.line,
            rule,
            f"`{name}` must be exactly `{expected}`, found `{found}`",
        )

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
            )
        return fields(given[1]) if given else {}

    def unknown_path(self, path: Node, rule: str) -> None:
        """Report a checkout ``path`` that cannot be classified.

        Args:
            path: The ``path`` value node.
            rule: Rule slug for the violation.
        """
        shown = path.text if path.kind == SCALAR else f"a {path.kind}"
        self.fail(
            path.line,
            rule,
            f"checkout `path: {shown}` cannot be told apart from "
            f"{TOOLING_PATH}; write the path so that its last component is "
            "a literal",
        )

    def check_case(self, inputs: dict[str, tuple[Node, Node]], rule: str) -> None:
        """Require lower-case input names.

        GitHub ignores the case of input names, so a second spelling of a
        checked input could be the one the runner uses.

        Args:
            inputs: The step's ``with:`` entries.
            rule: Rule slug for the violation.
        """
        for name, (key, _) in inputs.items():
            if name != name.lower():
                self.fail(
                    key.line,
                    rule,
                    f"checkout input `{name}` must be written in lower case; "
                    "GitHub ignores the case of input names, so this check "
                    "cannot tell which spelling the runner uses",
                )

    def checkout_path(self, inputs: dict[str, tuple[Node, Node]], rule: str) -> str:
        """Classify a checkout's ``path`` and report one that cannot be.

        Args:
            inputs: The step's ``with:`` entries.
            rule: Rule slug for a path that cannot be classified.

        Returns:
            str: The path kind (see :func:`classify_path`).
        """
        self.check_case(inputs, rule)
        path = inputs["path"][1] if "path" in inputs else None
        kind = classify_path(path)
        if kind == PATH_UNKNOWN and path is not None:
            self.unknown_path(path, rule)
        return kind

    def check_destination(
        self,
        inputs: dict[str, tuple[Node, Node]],
        repository: str,
        rule: str,
    ) -> None:
        """Keep a tooling checkout pointed at the tooling repository.

        The token goes wherever the checkout goes, so the checkout may set
        only the inputs in ``CHECKOUT_INPUTS``, and ``repository``, when
        set, must be the one expected value.

        Args:
            inputs: The step's ``with:`` entries.
            repository: The exact ``repository`` value allowed.
            rule: Rule slug for the violation.
        """
        allowed = ", ".join(sorted(CHECKOUT_INPUTS))
        for name, (key, _) in sorted(inputs.items()):
            if name not in CHECKOUT_INPUTS:
                message = f"a tooling checkout may not set `{name}`"
                message += f"; it may set only {allowed}"
                self.fail(key.line, rule, message)
        if "repository" in inputs:
            value = inputs["repository"][1]
            if value.kind != SCALAR or value.text != repository:
                found = value.text if value.kind == SCALAR else f"a {value.kind}"
                self.fail(
                    value.line,
                    rule,
                    f"`repository` of a tooling checkout must be exactly "
                    f"`{repository}`, found `{found}`",
                )
