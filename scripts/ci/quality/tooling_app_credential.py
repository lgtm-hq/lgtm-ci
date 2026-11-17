#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Rules for the optional tooling App credential (#1622).

Used by ``validate_tooling_token.py``; see its docstring for how files are
read. A reusable may take a GitHub App client ID and private key, the secrets
``LGTM_CI_TOOLING_APP_CLIENT_ID`` and ``LGTM_CI_TOOLING_APP_PRIVATE_KEY``.
Each job with a tooling consumer (a tooling checkout or a
``checkout-and-harden`` call) then mints an installation token right before
its first consumer, with the generated blocks ``tooling-app-flags`` and
``tooling-app-mint`` (sources under ``scripts/ci/bootstrap/``).

A file that names either secret, in any letter case, anywhere, takes the
pair, and then:

- ``app``: both secrets are declared under ``on.workflow_call.secrets`` with
  ``required: false``. Every job with a tooling consumer carries the two
  presence flags in its ``env:``, exactly, and the check and mint steps,
  exactly, as the two steps right before its first consumer, whichever kind
  it is. A job without a consumer has none of them. The consumers carry
  ``APP_TOKEN_EXPR`` and ``APP_FORWARD_EXPR`` (checked by the caller of this
  module): when either secret is set they yield the minted token or
  ``SENTINEL``, never a weaker fallback.
- ``app`` (condition): the steps run only when a consumer will. When every
  consumer of the job has an ``if:``, the job ``env:`` sets
  ``LGTM_CI_TOOLING_APP_NEEDED`` to exactly those conditions joined by
  ``||``; when any consumer is unconditional, it is absent. A condition the
  job ``env:`` cannot evaluate (status functions, ``steps``, ``runner``,
  ``env``, ``job``) is refused. When the harden-runner verification step is
  conditional, every consumer carries its condition.
- ``app`` (ambient): see ``tooling_app_ambient.py``.
- ``forward``: a local nested call whose target declares the pair forwards
  both secrets by name, and the pair goes only to such a target.
- ``leak``: the secret names, the step ids ``tooling-app-target`` and
  ``tooling-app-token`` and the ``LGTM_CI_TOOLING_APP_*`` variables appear
  only at the places above. Every ``steps`` of an expression must be followed
  by ``.NAME``, so no ``toJSON(steps)`` or ``steps[...]`` can reach the token
  by another route.

In a file that does not take the pair, any of these words is a ``leak``.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from pathlib import Path
from typing import Protocol

import tooling_app_ambient as ambient
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
NEEDED = "LGTM_CI_TOOLING_APP_NEEDED"
TARGET_ID = "tooling-app-target"
MINT_ID = "tooling-app-token"
VERIFY_ID = "verify-harden-runner"
# The minting action and pin of the release workflows; no second one.
MINT_PIN = "64ab729a6294000f5aa4a4bc0b73d1f32bc45510"
MINT_ACTION = f"actions/create-github-app-token@{MINT_PIN}"
# What a consumer gets when the App was requested and no token came out: not
# a token, no scanner prefix, and the checkout fails to authenticate with it.
SENTINEL = "no-tooling-app-token"  # nosec B105 - a placeholder, not a credential
# Either App secret set: the minted token or the sentinel, never a fallback.
REQUESTED = f"(secrets.{CLIENT_ID} != '' || secrets.{PRIVATE_KEY} != '')"
GRANTED = f"(steps.{MINT_ID}.outputs.token || '{SENTINEL}')"
STORED = "secrets.LGTM_CI_TOOLING_TOKEN"  # nosec B105 - an expression
FALLBACKS = f"{STORED} || github.token"
APP_TOKEN_EXPR = "${{ " + f"{REQUESTED} && {GRANTED} || {FALLBACKS}" + " }}"
APP_FORWARD_EXPR = "${{ " + f"{REQUESTED} && {GRANTED} || {STORED}" + " }}"

SECRET_NAMES = re.compile("|".join(SECRETS), re.I)
# Every word of the App credential: secrets, job variables, step ids.
WORDS = re.compile(
    r"LGTM_CI_TOOLING_APP_\w*|(?<![\w-])tooling-app-(?:target|token)(?![\w-])",
    re.I,
)
STEPS_WORD = re.compile(r"(?<![\w.-])steps(?![\w-])", re.I)
PROPERTY = re.compile(r"\s*\.\s*[A-Za-z_][\w-]*")
LOCAL_WORKFLOW = re.compile(r"\./\.github/workflows/([^/@]+\.ya?ml)")
WRAPPED = re.compile(r"\A\s*\$\{\{(.*)\}\}\s*\Z", re.S)
# What a job `env:` cannot evaluate when the job starts: the status
# functions and hashFiles, and the steps, runner, env and job contexts read in
# any way (a property, an index or the whole context, as in toJSON(runner)).
# Searched with string literals blanked, so a quoted word does not count.
LATE = re.compile(
    r"(?<![\w.-])(?:always|success|failure|cancelled|hashfiles)\s*\("
    r"|(?<![\w.-])(?:steps|runner|env|job)(?![\w-])",
    re.I,
)
# A string literal of an expression, with '' as an escaped quote.
LITERAL = re.compile(r"'(?:[^']|'')*'")

# Either App secret set, as the job variables say it.
PRESENT = f"(env.{ID_FLAG} == 'true' || env.{KEY_FLAG} == 'true')"
FLAGS = {
    ID_FLAG: "${{ secrets." + CLIENT_ID + " != '' }}",
    KEY_FLAG: "${{ secrets." + PRIVATE_KEY + " != '' }}",
}

Expected = dict[str, "str | Expected"]

# The two steps of scripts/ci/bootstrap/tooling-app-mint.yml, as parsed.
TARGET_STEP: Expected = {
    "name": "Check tooling App credential",
    "id": TARGET_ID,
    "if": f"env.{NEEDED} != 'false' && {PRESENT}",
    "shell": "bash",
    "env": {
        "TOOLING_REPOSITORY": WORKFLOW_REPOSITORY,
        "SHAPE": "^([A-Za-z0-9][A-Za-z0-9_-]*)/([A-Za-z0-9._-]+)$",
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


def condition(step: Node) -> str | None:
    """Return a step's ``if:`` without ``${{ }}``, or None when it has none.

    Args:
        step: The step mapping.

    Returns:
        str | None: The condition with runs of whitespace outside string
        literals collapsed to one space; literals are kept as written.
    """
    node = descend(step, "if")
    if node is None or node.kind != SCALAR or not node.text.strip():
        return None
    wrapped = WRAPPED.match(node.text)
    text = (wrapped.group(1) if wrapped else node.text).strip()
    pieces = re.split(f"({LITERAL.pattern})", text)
    code = [re.sub(r"\s+", " ", piece) for piece in pieces[::2]]
    pieces[::2] = code
    return "".join(pieces).strip()


def is_late(found: str) -> bool:
    """Tell whether a condition reads what a job ``env:`` cannot evaluate."""
    return LATE.search(blank_literals(found)) is not None


def blank_literals(text: str) -> str:
    """Return a condition with each string literal emptied to ``''``."""
    return LITERAL.sub("''", text)


def needed_value(conditions: list[str | None]) -> str | None:
    """Return the ``LGTM_CI_TOOLING_APP_NEEDED`` value the consumers call for.

    Args:
        conditions: Each consumer's condition, in step order.

    Returns:
        str | None: None when a consumer is unconditional (the variable must
        be absent); otherwise an expression that is exactly ``'true'`` or
        ``'false'``: the distinct conditions, each in parentheses, joined by
        ``||`` and turned into a Boolean string by ``&& 'true' || 'false'``,
        so a condition whose value is a string such as ``'false'`` or ``''``
        decides the mint the same way it decides the consumer.
    """
    if any(found is None for found in conditions):
        return None
    distinct = list(dict.fromkeys(str(found) for found in conditions))
    joined = " || ".join(f"({found})" for found in distinct)
    if len(distinct) > 1:
        joined = f"({joined})"
    return "${{ " + joined + " && 'true' || 'false' }}"


def check_needed(
    check: Workflow,
    job: Node,
    steps: list[Node],
    consumers: list[int],
) -> None:
    """Tie the mint's condition to the job's consumers.

    Args:
        check: The workflow check.
        job: The job mapping.
        steps: The job's steps.
        consumers: Indexes of the job's tooling consumers.
    """
    conditions = [condition(steps[index]) for index in consumers]
    # Only when every consumer is conditional does the mint follow them.
    late: list[str] = []
    if None not in conditions:
        late = sorted({str(found) for found in conditions if is_late(str(found))})
    for found in late:
        check.fail(
            steps[consumers[0]].line,
            "app",
            f"consumer condition `{found}` cannot be evaluated when the job starts, "
            f"so `{NEEDED}` cannot follow it; make the first tooling consumer "
            "unconditional or condition it on inputs, needs, github, matrix or vars",
        )
    verify = [condition(step) for step in steps if step_id(step) == VERIFY_ID]
    guarded = [found for found in verify if found]
    if guarded and any(found != guarded[0] for found in conditions):
        check.fail(
            steps[consumers[0]].line,
            "app",
            f"the harden-runner verification runs only when `{guarded[0]}`; every "
            "tooling consumer must carry that condition, so the App token is never "
            "minted or used where the verification does not run",
        )
    expected = None if late else needed_value(conditions)
    entry = fields(descend(job, "env")).get(NEEDED)
    if entry is not None:
        check.settled.update((id(entry[0]), id(entry[1])))
    if expected is None and entry is not None and not late:
        check.fail(
            entry[0].line,
            "app",
            f"`{NEEDED}` must be absent: a tooling consumer of this job is "
            "unconditional, so the App token is needed whenever the job runs",
        )
    elif expected is not None and entry is None:
        check.fail(
            job.line,
            "app",
            f"every tooling consumer is conditional, so the job's `env:` must set "
            f"`{NEEDED}: {expected}`",
        )
    elif expected is not None and entry is not None:
        for problem in differences(entry[1], expected, f"env.{NEEDED}"):
            message = f"{problem}; it must equal the consumers' conditions"
            check.fail(entry[1].line, "app", message)


def check_job(check: Workflow, anchor: Node, job: Node) -> int | None:
    """Apply the ``app`` rule to one job of a file that takes the pair.

    Args:
        check: The workflow check.
        anchor: The job's key node.
        job: The job mapping.

    Returns:
        int | None: The check step's index when the job mints, else None.
    """
    sequence = descend(job, "steps")
    steps = sequence.items if sequence and sequence.kind == SEQUENCE else []
    consumers = [
        index
        for index, step in enumerate(steps)
        if uses_id(step) in check.tooling_uses | check.composite_uses
    ]
    targets = [i for i, step in enumerate(steps) if step_id(step) == TARGET_ID]
    mints = [i for i, step in enumerate(steps) if step_id(step) == MINT_ID]
    if not consumers:
        for index in targets + mints:
            check.fail(
                steps[index].line,
                "app",
                "a tooling App step in a job without a tooling consumer; the "
                "token may only be minted right before one",
            )
        return None
    check_flags(check, job, anchor)
    check_needed(check, job, steps, consumers)
    if len(targets) != 1 or len(mints) != 1:
        check.fail(
            anchor.line,
            "app",
            f"the job needs exactly one `{TARGET_ID}` and one `{MINT_ID}` step "
            "(generated block tooling-app-mint)",
        )
        return None
    target, mint = targets[0], mints[0]
    check_step(check, steps[target], TARGET_STEP, TARGET_ID)
    check_step(check, steps[mint], MINT_STEP, MINT_ID)
    if mint != target + 1 or consumers[0] != mint + 1:
        check.fail(
            steps[mint].line,
            "app",
            f"`{TARGET_ID}` and `{MINT_ID}` must be the two steps right before the "
            "job's first tooling consumer (a tooling checkout or a "
            "checkout-and-harden call)",
        )
    return target


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
    minting: list[tuple[Node, Node, int]] = []
    for key, job in fields(descend(check.root, "jobs")).values():
        if job.kind != MAPPING:
            continue
        if "uses" in fields(job):
            check_forward(check, job)
            continue
        target = check_job(check, key, job) if pair else None
        if target is not None:
            minting.append((job, fields(job)["steps"][1], target))
    if pair:
        check_declaration(check)
        ambient.check_ambient(check, minting)


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
