#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Rules for the optional tooling App credential (#1622).

Used by ``validate_tooling_token.py``; see its docstring for how files are
read. A reusable may take a GitHub App client ID and private key, the secrets
``LGTM_CI_TOOLING_APP_CLIENT_ID`` and ``LGTM_CI_TOOLING_APP_PRIVATE_KEY``.
Each job that checks out the tooling then mints an installation token right
before that checkout, with the generated blocks ``tooling-app-flags`` and
``tooling-app-mint`` (sources under ``scripts/ci/bootstrap/``).

A file that names either secret, in any letter case, anywhere, takes the
pair, and then:

- ``app``: both secrets are declared under ``on.workflow_call.secrets`` with
  ``required: false``. Every job with a tooling checkout or a
  ``checkout-and-harden`` call carries the two presence flags in its
  ``env:``, exactly, and the check and mint steps, exactly, as the two steps
  right before its first tooling checkout. A job without a tooling checkout
  has none of them. The tooling checkout's ``token:`` and the composite
  call's ``tooling-token:`` are the App expressions (checked by the caller of
  this module).
- ``forward``: a local nested call whose target declares the pair forwards
  both secrets by name, and the pair goes only to such a target.
- ``leak``: the secret names, the step ids ``tooling-app-target`` and
  ``tooling-app-token`` and the flag names appear only at the places above.
  Every ``steps`` of an expression must be followed by ``.NAME``, so no
  ``toJSON(steps)`` or ``steps[...]`` can reach the token by another route.

In a file that does not take the pair, any of these words is a ``leak``.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from pathlib import Path
from typing import Protocol

from tooling_token_yaml import (
    MAPPING,
    SCALAR,
    SEQUENCE,
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

CLIENT_ID = "LGTM_CI_TOOLING_APP_CLIENT_ID"
PRIVATE_KEY = "LGTM_CI_TOOLING_APP_PRIVATE_KEY"  # nosec B105 - a secret's name
SECRETS = (CLIENT_ID, PRIVATE_KEY)
ID_FLAG = "LGTM_CI_TOOLING_APP_ID_SET"
KEY_FLAG = "LGTM_CI_TOOLING_APP_KEY_SET"
TARGET_ID = "tooling-app-target"
MINT_ID = "tooling-app-token"
# The minting action and pin of the release workflows; no second one.
MINT_PIN = "64ab729a6294000f5aa4a4bc0b73d1f32bc45510"
MINT_ACTION = f"actions/create-github-app-token@{MINT_PIN}"
# App token, then the stored token; the checkout falls back to github.token.
MINTED = f"steps.{MINT_ID}.outputs.token"
STORED = "secrets.LGTM_CI_TOOLING_TOKEN"  # nosec B105 - an expression
APP_TOKEN_EXPR = "${{ " + f"{MINTED} || {STORED} || github.token" + " }}"
APP_FORWARD_EXPR = "${{ " + f"{MINTED} || {STORED}" + " }}"

SECRET_NAMES = re.compile("|".join(SECRETS), re.I)
# Every word of the App credential: both secrets, both flags, both step ids.
WORDS = re.compile(
    r"LGTM_CI_TOOLING_APP_\w*|(?<![\w-])tooling-app-(?:target|token)(?![\w-])",
    re.I,
)
STEPS_WORD = re.compile(r"(?<![\w.-])steps(?![\w-])", re.I)
PROPERTY = re.compile(r"\s*\.\s*[A-Za-z_][\w-]*")
LOCAL_WORKFLOW = re.compile(r"\./\.github/workflows/([^/@]+\.ya?ml)")

FLAGS = {
    ID_FLAG: "${{ secrets." + CLIENT_ID + " != '' }}",
    KEY_FLAG: "${{ secrets." + PRIVATE_KEY + " != '' }}",
}

Expected = dict[str, "str | Expected"]

# The two steps of scripts/ci/bootstrap/tooling-app-mint.yml, as parsed.
TARGET_STEP: Expected = {
    "name": "Check tooling App credential",
    "id": TARGET_ID,
    "if": f"env.{ID_FLAG} == 'true' || env.{KEY_FLAG} == 'true'",
    "shell": "bash",
    "env": {
        "TOOLING_REPOSITORY": WORKFLOW_REPOSITORY,
        "SHAPE": "^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$",
        "INCOMPLETE": (
            "::error title=incomplete tooling App credential::pass both "
            f"{CLIENT_ID} and {PRIVATE_KEY}, or neither"
        ),
        "UNREADABLE": (
            "::error title=unreadable tooling repository::cannot split the "
            "tooling repository into an owner and a name"
        ),
    },
    "run": (
        f'[[ "${{{ID_FLAG}}}" == "${{{KEY_FLAG}}}" ]] || '
        '{ echo "${INCOMPLETE}"; exit 1; }\n'
        '[[ "${TOOLING_REPOSITORY}" =~ ${SHAPE} ]] || '
        '{ echo "${UNREADABLE}"; exit 1; }\n'
        "printf 'owner=%s\\nrepository=%s\\n' "
        '"${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "${GITHUB_OUTPUT}"\n'
    ),
}
MINT_STEP: Expected = {
    "name": "Mint tooling App token",
    "id": MINT_ID,
    "if": f"steps.{TARGET_ID}.outputs.repository != ''",
    "uses": MINT_ACTION,
    "with": {
        "client-id": "${{ secrets." + CLIENT_ID + " }}",
        "private-key": "${{ secrets." + PRIVATE_KEY + " }}",
        "owner": "${{ steps." + TARGET_ID + ".outputs.owner }}",
        "repositories": "${{ steps." + TARGET_ID + ".outputs.repository }}",
        "permission-contents": "read",
    },
}


class Workflow(Protocol):  # pylint: disable=too-few-public-methods
    """What these rules need from the workflow check that calls them."""

    path: Path
    root: Node | None
    settled: set[int]
    tooling_uses: set[int]
    composite_uses: set[int]

    def fail(self, line: int, rule: str, message: str) -> None:
        """Record a violation."""

    def scalars(self) -> list[tuple[Node, str]]:
        """Return every scalar of the file with its key."""


def takes_pair(scalars: Iterable[tuple[Node, str]]) -> bool:
    """Tell whether a file names either App secret anywhere.

    Args:
        scalars: Every scalar of the file, keys included.

    Returns:
        bool: True when the file takes the App credential.
    """
    return any(SECRET_NAMES.search(node.text) for node, _ in scalars)


def differences(node: Node, expected: str | Expected, where: str) -> list[str]:
    """Compare a node with its exact expected shape.

    Args:
        node: The node found.
        expected: A scalar's exact text, or a mapping's exact entries.
        where: The dotted path of ``node``, for the message.

    Returns:
        list[str]: One message per difference; empty when equal.
    """
    if isinstance(expected, str):
        if node.kind == SCALAR and node.text == expected:
            return []
        found = node.text if node.kind == SCALAR else f"a {node.kind}"
        return [f"`{where}` must be exactly `{expected}`, found `{found}`"]
    if node.kind != MAPPING:
        return [f"`{where}` must be a mapping"]
    entries = fields(node)
    problems = [
        f"`{where}.{name}` is not part of the generated step"
        for name in entries
        if name not in expected
    ]
    for name, value in expected.items():
        if name not in entries:
            problems.append(f"`{where}.{name}` is missing")
        else:
            problems += differences(entries[name][1], value, f"{where}.{name}")
    return problems


def settle(check: Workflow, node: Node) -> None:
    """Mark every scalar under ``node`` as checked.

    Args:
        check: The workflow check.
        node: The step or entry whose scalars were found exact.
    """
    check.settled.update(id(child) for child, _ in walk(node) if child.kind == SCALAR)


def step_id(step: Node) -> str:
    """Return a step's ``id`` in lower case, or an empty string."""
    entry = fields(step).get("id")
    return entry[1].text.lower() if entry and entry[1].kind == SCALAR else ""


def uses_id(step: Node) -> int:
    """Return the identity of a step's ``uses`` value node, or 0."""
    entry = fields(step).get("uses")
    return id(entry[1]) if entry else 0


def check_declaration(check: Workflow) -> None:
    """Require both secrets under ``on.workflow_call.secrets``, optional.

    Args:
        check: The workflow check.
    """
    declared = descend(check.root, "on", "workflow_call", "secrets")
    entries = fields(declared)
    for name in SECRETS:
        entry = entries.get(name)
        if entry is None:
            line = declared.line if declared else 1
            check.fail(
                line,
                "app",
                f"names the tooling App credential but does not declare secret "
                f"{name} under on.workflow_call.secrets with `required: false`",
            )
            continue
        check.settled.add(id(entry[0]))
        required = descend(entry[1], "required")
        if required is None or required.kind != SCALAR or required.text != "false":
            check.fail(
                entry[0].line,
                "app",
                f"secret {name} must be declared with `required: false`",
            )


def check_flags(check: Workflow, job: Node, anchor: Node) -> None:
    """Require the two presence flags in a job's ``env:``.

    Args:
        check: The workflow check.
        job: The job mapping.
        anchor: The job's key node, reported when ``env`` is missing.
    """
    env = descend(job, "env")
    entries = fields(env)
    for name, expected in FLAGS.items():
        if name not in entries:
            check.fail(
                (env or anchor).line,
                "app",
                f"the job's `env:` is missing `{name}: {expected}` "
                "(generated block tooling-app-flags)",
            )
            continue
        key, value = entries[name]
        check.settled.add(id(key))
        for problem in differences(value, expected, f"env.{name}"):
            check.fail(value.line, "app", problem)
        if value.kind == SCALAR:
            check.settled.add(id(value))


def check_step(check: Workflow, step: Node, expected: Expected, label: str) -> None:
    """Hold one generated step to its exact shape.

    Args:
        check: The workflow check.
        step: The step mapping.
        expected: Its exact entries.
        label: The step id, for the message.
    """
    problems = differences(step, expected, label)
    for problem in problems:
        check.fail(step.line, "app", f"{problem} (generated block tooling-app-mint)")
    if not problems:
        settle(check, step)


def check_job(check: Workflow, anchor: Node, job: Node) -> None:
    """Apply the ``app`` rule to one job of a file that takes the pair.

    Args:
        check: The workflow check.
        anchor: The job's key node.
        job: The job mapping.
    """
    sequence = descend(job, "steps")
    steps = sequence.items if sequence and sequence.kind == SEQUENCE else []
    tooling = [i for i, step in enumerate(steps) if uses_id(step) in check.tooling_uses]
    calls = [i for i, step in enumerate(steps) if uses_id(step) in check.composite_uses]
    targets = [i for i, step in enumerate(steps) if step_id(step) == TARGET_ID]
    mints = [i for i, step in enumerate(steps) if step_id(step) == MINT_ID]
    if not tooling and not calls:
        for index in targets + mints:
            check.fail(
                steps[index].line,
                "app",
                "a tooling App step in a job without a tooling checkout; the "
                "token may only be minted right before one",
            )
        return
    check_flags(check, job, anchor)
    if len(targets) != 1 or len(mints) != 1:
        check.fail(
            anchor.line,
            "app",
            f"the job needs exactly one `{TARGET_ID}` and one `{MINT_ID}` step "
            "(generated block tooling-app-mint)",
        )
        return
    target, mint = targets[0], mints[0]
    check_step(check, steps[target], TARGET_STEP, TARGET_ID)
    check_step(check, steps[mint], MINT_STEP, MINT_ID)
    first = tooling[0] if tooling else None
    if mint != target + 1 or first != mint + 1 or any(i < mint for i in calls):
        check.fail(
            steps[mint].line,
            "app",
            f"`{TARGET_ID}` and `{MINT_ID}` must be the two steps right before "
            "the job's first tooling checkout, and before every "
            "checkout-and-harden call",
        )


def target_declares(path: Path) -> bool | None:
    """Tell whether a workflow file declares either App secret.

    Args:
        path: The workflow file.

    Returns:
        bool | None: None when the file does not exist.
    """
    if not path.is_file():
        return None
    entries = fields(descend(load(path)[0], "on", "workflow_call", "secrets"))
    return any(name in entries for name in SECRETS)


def check_forward(check: Workflow, job: Node) -> None:
    """Apply the ``forward`` rule to one nested call.

    Args:
        check: The workflow check.
        job: A job mapping with a ``uses:``.
    """
    uses = fields(job)["uses"][1]
    local = LOCAL_WORKFLOW.fullmatch(uses.text.strip()) if uses.kind == SCALAR else None
    declared = target_declares(check.path.parent / local.group(1)) if local else None
    given = fields(descend(job, "secrets"))
    for name in SECRETS:
        expected = "${{ secrets." + name + " }}"
        if name not in given:
            if declared:
                check.fail(uses.line, "forward", f"missing `{name}: {expected}`")
            continue
        key, value = given[name]
        if not declared:
            check.fail(
                key.line,
                "leak" if local is None else "forward",
                f"forwards {name} to `{uses.text}`, which is not a "
                "`./.github/workflows/<file>` of this repository that declares it",
            )
            continue
        check.settled.add(id(key))
        for problem in differences(value, expected, f"secrets.{name}"):
            check.fail(value.line, "forward", problem)
        if value.kind == SCALAR:
            check.settled.add(id(value))


def check_structure(check: Workflow, pair: bool) -> None:
    """Apply the ``app`` and ``forward`` rules to every job.

    Args:
        check: The workflow check.
        pair: Whether the file takes the App credential.
    """
    for key, job in fields(descend(check.root, "jobs")).values():
        if job.kind != MAPPING:
            continue
        if "uses" in fields(job):
            check_forward(check, job)
        elif pair:
            check_job(check, key, job)
    if pair:
        check_declaration(check)


def check_words(check: Workflow, pair: bool) -> None:
    """Apply the ``leak`` rule once every permitted place is settled.

    Args:
        check: The workflow check.
        pair: Whether the file takes the App credential.
    """
    for node, key in check.scalars():
        if id(node) in check.settled:
            continue
        for match in WORDS.finditer(node.text):
            check.fail(
                line_at(node, match.start()),
                "leak",
                f"`{match.group(0)}` may appear only in the generated tooling App "
                "blocks, the secret declarations, a nested call's `secrets` and "
                "the tooling checkout's token expressions",
            )
        if not pair or not is_expression(node, key):
            continue
        for offset in loose_reads(node.text, STEPS_WORD, PROPERTY):
            check.fail(
                line_at(node, offset),
                "leak",
                "the expression reads the steps context as a whole or by index, "
                f"which can expose the `{MINT_ID}` token; every `steps` must be "
                "`steps.NAME`, string literals included",
            )
