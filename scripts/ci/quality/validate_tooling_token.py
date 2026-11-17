#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# pylint: disable=too-many-lines  # One validator; its rules read best together.
"""Check how reusable workflows handle the optional tooling token (#1451).

Usage: validate_tooling_token.py --workflows-dir DIR --actions-dir DIR

A private mirror of this repository needs a credential for the tooling
checkout, so a converted reusable takes the optional secret
``LGTM_CI_TOOLING_TOKEN`` and hands it to that checkout and to nothing else.

Principle. A value is allowed when it is exactly a permitted text at a
permitted place; everything else is denied. Nothing is exempt because of
where it sits, and no expression is parsed: a scalar is compared as a whole.

How the files are read. Every ``*.yml`` and ``*.yaml`` under the workflows
directory is parsed with PyYAML into a node tree, with aliases expanded, so a
step is seen the same way whether it is written in block style, flow style,
through an anchor, or with quoted or folded scalars. A file that does not
parse is an error whatever its name. A file is checked when its name starts
with ``reusable-`` or it has ``on.workflow_call``. Every mapping with a
``uses:`` key is classified, wherever it sits:

- tooling checkout: ``actions/checkout`` (any case) whose ``with.path``
  normalises to ``.lgtm-ci-tooling``, or whose ``with.repository`` is
  exactly ``${{ job.workflow_repository }}`` or
  ``${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}`` whatever its path;
- composite call: ``./.lgtm-ci-tooling/.github/actions/checkout-and-harden``,
  with or without a trailing slash, and no other spelling. That is the copy
  the tooling checkout staged, the one this check has read. A remote
  ``<owner>/<repo>/.github/actions/checkout-and-harden@<ref>`` runs whatever
  that repository holds at that ref, and this repository's own name cannot be
  known here without breaking mirrors, so every remote form is unclassified.
  ``./.github/actions/checkout-and-harden`` is the caller's repository in a
  called workflow, so it is unclassified too;
- nested call: a ``uses:`` that ends in ``.github/workflows/<file>``. It is
  local when it is exactly ``./.github/workflows/<file>``.

Each violation is printed as ``file:line: [rule] message``:

- ``token``: a tooling checkout must carry
  ``token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}`` and
  ``persist-credentials: false``.
- ``composite-call``: a composite call must pass
  ``tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}``.
- ``declaration``: a file that does either must declare the secret under
  ``on.workflow_call.secrets`` with ``required: false``.
- ``forward``: a local nested call whose target declares the secret must
  forward it by name, and the secret may be forwarded only to a local target
  that exists and declares it.
- ``unclassified``: what cannot be classified is an error, never "not
  tooling". A checkout whose ``path`` holds an expression, unless its last
  path component is a literal other than ``.lgtm-ci-tooling``, ``.`` or
  ``..``; a literal path that mentions ``.lgtm-ci-tooling`` without
  normalising to it; ``.lgtm-ci-tooling`` as the ``with.path`` of a step that
  is not ``actions/checkout``; ``checkout-and-harden`` in a ``uses:`` that is
  not the composite call; and, in a file that names the secret, a nested call
  that is remote or whose target file does not exist.
- ``yaml``: the file cannot be read as GitHub would read it: it does not
  parse, is nested more than ``MAX_DEPTH`` levels, repeats a key, uses a merge
  key (``<<``, which GitHub Actions does not support), or is an empty or
  non-mapping file named ``reusable-*``.
- ``leak``: applies to a file that names the secret, in any letter case,
  anywhere in a key or a value. A scalar that names the secret must be the
  declaration key, the forwarded key of a local nested call, or exactly one
  of the three values above at its place. A scalar that holds ``${{``, and
  every ``if:``, is searched as a whole for the word ``secrets``: each one
  must be followed by ``.NAME``. ``toJSON(secrets)``, ``secrets[...]``,
  ``secrets.*`` and a bare ``secrets`` are leaks, and so is the word inside a
  string literal, because telling a literal from code needs the parsing this
  check refuses to do. No job may say ``secrets: inherit``, and the secret
  may not be forwarded to a remote workflow.
- ``composite``: in ``checkout-and-harden/action.yml`` the tooling checkout
  must carry ``token: ${{ inputs.tooling-token || github.token }}`` and
  ``persist-credentials: false``. In every scalar that holds ``${{`` and in
  every ``if:``, ``tooling-token`` in any letter case may appear only as that
  exact ``token:`` value, and each ``inputs`` must be followed by ``.name``
  or ``['name']``. Every other ``action.yml`` or ``action.yaml`` under the
  actions directory is read too: no step in it may have ``.lgtm-ci-tooling``
  as its ``with.path``, and a checkout whose ``path`` cannot be told apart
  from it is an error, except the pass-through ``path: ${{ inputs.path }}``
  of an input whose default is not the tooling directory (the caller's
  ``with.path`` is then covered by ``unclassified``).

- ``app``: a file that names a tooling App secret (#1622) takes the App
  credential. Its tooling checkouts and composite calls carry the App
  expressions instead of the two above, and the rules of
  ``tooling_app_credential.py`` apply: the generated mint steps, exactly,
  right before each job's first tooling checkout, and no other use of the
  minted token, the App secrets or the step ids.

Every rule applies to every checked file; no file is exempt.

Not seen: a reusable that never names the secret is not searched for reads of
the whole ``secrets`` context; a ``run:`` script that clones the tooling by
hand; and what a called action does with the values it is given.
"""

from __future__ import annotations

import argparse
import posixpath
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

try:
    import yaml  # noqa: F401  # pylint: disable=unused-import
except ImportError:  # pragma: no cover - only on an interpreter without PyYAML
    print("ERROR: validate_tooling_token.py needs PyYAML", file=sys.stderr)
    sys.exit(2)

# The YAML reader and the App credential rules live next to this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
# pylint: disable=wrong-import-position
import tooling_app_credential as app  # noqa: E402
from tooling_token_yaml import (  # noqa: E402
    MAPPING,
    SCALAR,
    TOOLING_PATH,
    WORKFLOW_REPOSITORY,
    Node,
    descend,
    fields,
    is_expression,
    line_at,
    load,
    loose_reads,
    walk,
)

# pylint: enable=wrong-import-position

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


class WorkflowCheck(Check):
    """Collects the violations of one reusable workflow.

    Args:
        path: The reusable workflow file, read and parsed on construction.
    """

    def __init__(self, path: Path) -> None:
        super().__init__(path)
        self.first_use: int | None = None
        self.inherits: list[tuple[Node, str, bool | None]] = []
        self.tooling_uses: set[int] = set()
        self.composite_uses: set[int] = set()
        # Takes the tooling App credential (#1622): see tooling_app_credential.
        self.pair = app.takes_pair(self.scalars())
        names_token = any(SECRET_NAME.search(node.text) for node, _ in self.scalars())
        self.named = self.pair or names_token
        # A value naming either credential is settled where it is checked.
        self.guarded = re.compile(f"{SECRET_NAME.pattern}|{app.WORDS.pattern}", re.I)

    def check_forwarded(
        self,
        uses: Node,
        name: str,
        declared: bool | None,
        forwarded: dict[str, tuple[Node, Node]],
    ) -> bool:
        """Check a nested call that has the secret among its ``secrets:``.

        Args:
            uses: The job's ``uses`` value node.
            name: The called file's name; empty for a call that is not local.
            declared: Whether that file declares the secret; None when it does
                not exist.
            forwarded: The entries of the job's ``secrets:`` mapping.

        Returns:
            bool: Whether the secret goes to a target that may take it.
        """
        key, value = forwarded[SECRET]
        if not name:
            problem = (
                f"forwards {SECRET} to `{uses.text}`, which is not a "
                "`./.github/workflows/<file>` of this repository"
            )
            rule = "leak"
        elif declared is None:
            problem = f"forwards {SECRET} to {name}, which does not exist"
            rule = "forward"
        elif not declared:
            problem = f"forwards {SECRET} to {name}, which does not declare it"
            rule = "forward"
        else:
            self.settled.add(id(key))
            self.expect(
                keys=forwarded,
                name=SECRET,
                expected=FORWARD_EXPR,
                anchor=uses,
                rule="forward",
                guard=SECRET_NAME,
            )
            return True
        self.settled.update((id(key), id(value)))
        self.fail(key.line, rule, problem)
        return False

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
        local = LOCAL_WORKFLOW.fullmatch(uses.text.strip())
        name = local.group(1) if local else ""
        declared = declares(self.path.parent / name) if local else None
        given = keys["secrets"][1] if "secrets" in keys else None
        if given and given.kind == SCALAR and given.text.strip().lower() == "inherit":
            self.inherits.append((given, name or target, declared))
            return bool(declared)
        forwarded = fields(given)
        if SECRET in forwarded:
            return self.check_forwarded(uses, name, declared, forwarded)
        if declared:
            self.expect(
                keys=forwarded,
                name=SECRET,
                expected=FORWARD_EXPR,
                anchor=uses,
                rule="forward",
            )
            return True
        if self.named and declared is None:
            reason = "does not exist" if local else "is not a local workflow file"
            self.fail(
                uses.line,
                "unclassified",
                f"`uses: {uses.text}` {reason}, so whether it takes {SECRET} "
                "cannot be checked; in a file that names the secret a nested "
                "call must be `./.github/workflows/<file>`",
            )
        return False

    def check_checkout(
        self,
        inputs: dict[str, tuple[Node, Node]],
        uses: Node,
        repository: str = WORKFLOW_REPOSITORY,
    ) -> None:
        """Apply the ``token`` rule to one tooling checkout.

        Args:
            inputs: The step's ``with:`` entries.
            uses: The step's ``uses`` value node.
            repository: The exact ``repository`` value allowed.
        """
        self.tooling_uses.add(id(uses))
        self.check_destination(inputs, repository, "token")
        self.expect(
            keys=inputs,
            name="token",
            expected=app.APP_TOKEN_EXPR if self.pair else TOKEN_EXPR,
            anchor=uses,
            rule="token",
            guard=self.guarded,
        )
        self.expect(
            keys=inputs,
            name="persist-credentials",
            expected="false",
            anchor=uses,
            rule="token",
        )

    def check_step(  # pylint: disable=too-many-return-statements
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
            bool: Whether this is a classified place the tooling token
            applies to. A step that cannot be classified is reported on its
            own and is not counted as a use.
        """
        if kind == NESTED:
            return self.check_nested(uses, target, keys)
        if kind == COMPOSITE_MENTION:
            self.fail(
                uses.line,
                "unclassified",
                f"`uses: {uses.text}` names {COMPOSITE} but is not "
                f"`./{TOOLING_PATH}/.github/actions/{COMPOSITE}`, the staged "
                "copy and the only one this check has read",
            )
            return False
        inputs = self.step_inputs(keys, uses, "unclassified")
        if kind == COMPOSITE_CALL:
            self.check_case(inputs, "composite-call")
            if "tooling-repository" in inputs:
                value = inputs["tooling-repository"][1]
                if value.kind != SCALAR or value.text != WORKFLOW_REPOSITORY:
                    found = value.text if value.kind == SCALAR else f"a {value.kind}"
                    self.fail(
                        value.line,
                        "composite-call",
                        "`tooling-repository` must be exactly "
                        f"`{WORKFLOW_REPOSITORY}`, found `{found}`",
                    )
            self.composite_uses.add(id(uses))
            self.expect(
                keys=inputs,
                name=INPUT,
                expected=app.APP_FORWARD_EXPR if self.pair else FORWARD_EXPR,
                anchor=uses,
                rule="composite-call",
                guard=self.guarded,
            )
            return True
        if kind == OTHER:
            where = classify_path(inputs["path"][1] if "path" in inputs else None)
        else:
            where = self.checkout_path(inputs, "unclassified")
        if where != PATH_TOOLING:
            named = inputs.get("repository", (None, None))[1]
            if (
                kind == CHECKOUT
                and named is not None
                and named.kind == SCALAR
                and named.text in SELF_REPOSITORIES
            ):
                # Another directory, the same tooling repository.
                self.check_checkout(inputs, uses, named.text)
                return True
            return False
        if kind != CHECKOUT:
            self.fail(
                uses.line,
                "unclassified",
                f"`uses: {uses.text}` writes to {TOOLING_PATH} but is not "
                "actions/checkout, so its token cannot be checked",
            )
            return False
        self.check_checkout(inputs, uses)
        return True

    def check_declaration(self) -> None:
        """Apply the ``declaration`` rule once every use is known."""
        key, optional = secret_declaration(self.root)
        if key is not None:
            self.settled.add(id(key))
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
        for node, key in self.scalars():
            if id(node) in self.settled:
                continue
            for match in SECRET_NAME.finditer(node.text):
                self.fail(
                    line_at(node, match.start()),
                    "leak",
                    f"{SECRET} may only be declared, passed to the tooling "
                    f"checkout's `token`, to {COMPOSITE}'s `{INPUT}` and to a "
                    "nested reusable's `secrets`",
                )
            if not self.named or not is_expression(node, key):
                continue
            for offset in loose_reads(node.text, SECRETS_WORD, PROPERTY):
                self.fail(
                    line_at(node, offset),
                    "leak",
                    "the expression reads the secrets context as a whole or "
                    f"by index, which can expose {SECRET}; in a file that names "
                    "that secret every `secrets` of an expression must be "
                    "`secrets.NAME`, string literals included",
                )
        for node, target, declared in self.inherits:
            if self.named:
                self.fail(
                    node.line,
                    "leak",
                    f"`secrets: inherit` hands every secret, {SECRET} included, "
                    f"to {target}; forward secrets by name",
                )
            elif declared:
                self.fail(
                    node.line,
                    "forward",
                    f"`secrets: inherit` is not accepted; forward {SECRET} to {target}",
                )

    @property
    def uses_tooling(self) -> bool:
        """Whether the file has anything the token applies to; set by :meth:`run`."""
        return self.first_use is not None

    def run(self) -> list[Finding]:
        """Check the whole workflow.

        Returns:
            list[Finding]: The violations found.
        """
        for line, message in self.problems:
            self.fail(line, "yaml", message)
        for keys, uses, kind, target in self.steps():
            if self.check_step(keys, uses, kind, target) and self.first_use is None:
                self.first_use = uses.line
        self.check_declaration()
        app.check_structure(self, self.pair)
        self.check_leaks()
        app.check_words(self, self.pair)
        return self.findings


class CompositeCheck(Check):
    """Collects the violations of one composite action.

    Args:
        path: The composite's ``action.yml`` or ``action.yaml``.
        label: The file name to print.
    """

    def broken(self, line: int, message: str) -> None:
        """Record a violation of the ``composite`` rule.

        Args:
            line: 1-based line number.
            message: What is wrong and what is expected.
        """
        self.fail(line, "composite", message)

    def check_reads(self) -> None:
        """Let only the permitted ``token:`` read the token input."""
        for node, key in self.scalars():
            if id(node) in self.settled or not is_expression(node, key):
                continue
            offsets = [match.start() for match in INPUT_NAME.finditer(node.text)]
            offsets += loose_reads(node.text, INPUTS_WORD, PROPERTY_OR_INDEX)
            for offset in sorted(set(offsets)):
                self.broken(
                    line_at(node, offset),
                    f"only the tooling checkout's `token:` may read inputs.{INPUT}",
                )

    def run(self) -> list[Finding]:
        """Check ``checkout-and-harden``, the one composite with the token.

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
            if self.checkout_path(inputs, "composite") != PATH_TOOLING:
                continue
            if kind != CHECKOUT:
                self.broken(
                    uses.line,
                    f"`uses: {uses.text}` is not actions/checkout but writes to "
                    f"the tooling directory {TOOLING_PATH}, which only it may do",
                )
                continue
            checkouts += 1
            self.check_destination(inputs, COMPOSITE_REPOSITORY, "composite")
            for name, expected, guard in (
                ("token", COMPOSITE_TOKEN_EXPR, ANYTHING),
                ("persist-credentials", "false", None),
            ):
                self.expect(
                    keys=inputs,
                    name=name,
                    expected=expected,
                    anchor=uses,
                    rule="composite",
                    subject="tooling checkout",
                    guard=guard,
                )
        if not checkouts:
            self.broken(1, f"no checkout with `path: {TOOLING_PATH}` found")
        self.check_reads()
        return self.findings

    def run_other(self) -> list[Finding]:
        """Check a composite that must not check out the tooling.

        Returns:
            list[Finding]: The violations found.
        """
        for line, message in self.problems:
            self.broken(line, message)
        default = classify_path(descend(self.root, "inputs", "path", "default"))
        for keys, uses, kind, _ in self.steps():
            inputs = self.step_inputs(keys, uses, "composite")
            path = inputs["path"][1] if "path" in inputs else None
            where = classify_path(path)
            checkout = kind in (CHECKOUT, CHECKOUT_LIKE)
            if checkout:
                self.check_case(inputs, "composite")
            if where == PATH_TOOLING:
                self.broken(
                    uses.line,
                    f"`uses: {uses.text}` has `path: {TOOLING_PATH}`; only "
                    f"{COMPOSITE} may check out the tooling",
                )
            elif where == PATH_UNKNOWN and path is not None and checkout:
                passed = path.kind == SCALAR and path.text.strip() == PASS_THROUGH_PATH
                if not passed or default not in (PATH_NONE, PATH_OTHER):
                    self.unknown_path(path, "composite")
        return self.findings


def check_composite(action: Path) -> list[Finding]:
    """Apply the ``composite`` rule to ``checkout-and-harden/action.yml``.

    Args:
        action: The composite's ``action.yml``.

    Returns:
        list[Finding]: The violations found.
    """
    name = f"{COMPOSITE}/{action.name}"
    if not action.is_file():
        return [Finding(file=name, line=1, rule="composite", message="file not found")]
    return CompositeCheck(action, name).run()


def check_composites(actions_dir: Path) -> list[Finding]:
    """Apply the ``composite`` rule to every composite action.

    Args:
        actions_dir: Directory holding the composite actions.

    Returns:
        list[Finding]: The violations of ``checkout-and-harden`` and of every
        other ``action.yml`` or ``action.yaml`` below the directory.
    """
    primary = actions_dir / COMPOSITE / "action.yml"
    if not primary.is_file() and primary.with_suffix(".yaml").is_file():
        primary = primary.with_suffix(".yaml")
    findings = check_composite(primary)
    others = [*actions_dir.rglob("action.yml"), *actions_dir.rglob("action.yaml")]
    for action in sorted(others):
        if action != primary and action.is_file():
            label = action.relative_to(actions_dir).as_posix()
            findings += CompositeCheck(action, label).run_other()
    return findings


def unreadable(check: WorkflowCheck) -> list[Finding]:
    """Report a workflow that has no usable top-level mapping.

    Runs before a file is filtered by name or trigger, because a file that
    cannot be read cannot be shown to be something other than a reusable.

    Args:
        check: The workflow, already parsed.

    Returns:
        list[Finding]: The parse problems of any file; for a file named
        ``reusable-*``, also being empty or not a mapping.
    """
    if check.root is None and check.problems:
        problems = check.problems
    elif not check.name.startswith("reusable-"):
        return []
    elif check.root is None:
        problems = [(1, "the file is empty, so it is not a reusable workflow")]
    elif check.root.kind != MAPPING:
        problems = [(check.root.line, "the top level is not a mapping")]
    else:
        return []
    return [
        Finding(file=check.name, line=line, rule="yaml", message=message)
        for line, message in problems
    ]


def validate(*, workflows_dir: Path, actions_dir: Path) -> tuple[list[Finding], int]:
    """Check every reusable workflow and every composite.

    Args:
        workflows_dir: Directory holding the workflow files.
        actions_dir: Directory holding the composite actions.

    Returns:
        tuple[list[Finding], int]: The violations and the number of converted
        reusables.
    """
    findings = check_composites(actions_dir)
    converted = 0
    files = [*workflows_dir.glob("*.yml"), *workflows_dir.glob("*.yaml")]
    for workflow in sorted(path for path in files if path.is_file()):
        check = WorkflowCheck(workflow)
        broken = unreadable(check)
        if broken:
            findings += broken
            continue
        named = workflow.name.startswith("reusable-")
        if not named and not is_reusable(check.root):
            continue
        findings += check.run()
        converted += check.uses_tooling
    return sorted(set(findings)), converted


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
    args = parser.parse_args(argv)
    for label, directory in (
        ("workflows", args.workflows_dir),
        ("actions", args.actions_dir),
    ):
        if not directory.is_dir():
            print(f"ERROR: {label} directory not found: {directory}", file=sys.stderr)
            return 2
    try:
        findings, converted = validate(
            workflows_dir=args.workflows_dir,
            actions_dir=args.actions_dir,
        )
    except RecursionError:
        print(
            "ERROR: tooling token contract violations:\n"
            "  - [yaml] a file is nested too deeply to be parsed",
            file=sys.stderr,
        )
        return 1
    if findings:
        print("ERROR: tooling token contract violations:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding.render()}", file=sys.stderr)
        return 1
    print(f"OK: tooling token contract satisfied ({converted} converted)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
