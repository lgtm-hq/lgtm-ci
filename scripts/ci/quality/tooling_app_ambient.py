#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""What reaches the tooling App mint besides its own ``with:`` (#1622).

Used by ``tooling_app_credential.py`` for a reusable that takes the tooling
App credential. The minting action, ``actions/create-github-app-token`` at the
pinned commit, reads its inputs from the process environment: every variable
whose name starts with ``INPUT_PERMISSION-`` becomes a requested permission
(``lib/get-permissions-from-inputs.js``), and Node reads ``NODE_OPTIONS`` and
the proxy variables before the action's code runs. The runner builds that
environment from the workflow ``env:``, the job ``env:``, the job container's
``env:``, the step's own ``with:`` and whatever earlier steps wrote to
``$GITHUB_ENV``. The mint step itself has no ``env:``: the exact-shape rule
forbids it.

Rule ``app`` (ambient), in a file that takes the pair:

- No ``env:`` at workflow, job or container level, and no ``env:`` of a step
  that runs before the mint in a minting job, may have a key that starts with
  ``INPUT`` followed by ``-`` or ``_``, a key that starts with ``NODE_``, a
  proxy variable (``HTTP_PROXY``, ``HTTPS_PROXY``, ``ALL_PROXY``), or a key
  built from an expression, in any letter case. Such an ``env:`` must be a
  mapping, not an expression that yields one.
- Before the check step, in a minting job, no caller code runs. Every
  ``uses:`` is a remote action pinned to a full commit (no ``./`` and no
  ``docker://``), no step sets ``working-directory``, and every ``run:`` is
  either exactly one generated inline block (``sync_inline_blocks.py`` ties
  it to its reviewed source) or free of the ``CALLER_CODE`` pattern: no
  ``GITHUB_ENV``, ``INPUT_PERMISSION``, ``GITHUB_WORKSPACE`` or
  ``github.workspace``, no relative path, and no interpreter or build tool.

What this cannot stop. The check reads text. It cannot see what a pinned
remote action does, and it cannot parse a shell script: code that runs before
the mint can still write any variable to ``$GITHUB_ENV`` by means the pattern
does not spell out. That is why no caller code may run before the mint: the
steps there are the runner hardening, the egress checks and the caller
checkout, which runs nothing it checks out. The real limit on what a token
can hold is the App's registration (Contents: Read-only, installed on the
tooling repository only); ``permission-contents: read`` only narrows a token
inside that limit.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from typing import Protocol

from tooling_token_yaml import MAPPING, SCALAR, Node, descend, fields

# Names a variable must not have where the mint can see it.
AMBIENT_KEY = re.compile(r"^\s*(?:input[-_]|node_|(?:https?|all)_proxy\s*$)", re.I)
REMOTE_PINNED = re.compile(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}")
CALLER_CODE = re.compile(
    r"github_env|input_permission|github_workspace|github\.workspace"
    r"|(?:^|[\s;&|(`$])(?:\.{1,2}/|~/)"
    r"|(?:^|[\s;&|(`])(?:bash|sh|zsh|source|python[\d.]*|node|ruby|perl|make|npm|npx"
    r"|pnpm|yarn|bun|bunx|uv|uvx|pip[\d.]*|cargo|go|deno|pwsh|java|exec|eval)"
    r"(?=[\s;)]|$)"
    r"|(?:^|[;&|]\s*)\.\s+\S",
    re.I | re.M,
)
GENERATED = re.compile(
    r"\A\s*# lgtm-ci-inline:begin (\S+)\n(?:(?!# lgtm-ci-inline:).*\n)*"
    r"# lgtm-ci-inline:end \1\s*\Z",
)


class Workflow(Protocol):  # pylint: disable=too-few-public-methods
    """What these rules need from the workflow check that calls them."""

    root: Node | None

    def fail(self, line: int, rule: str, message: str) -> None:
        """Record a violation."""


def env_mappings(root: Node | None) -> Iterator[tuple[str, Node]]:
    """Yield every workflow, job and job container ``env:`` with a label.

    Args:
        root: Root node of the workflow.

    Yields:
        tuple[str, Node]: Where the ``env:`` is, and its value node.
    """
    top = descend(root, "env")
    if top is not None:
        yield "workflow `env:`", top
    for key, job in fields(descend(root, "jobs")).values():
        for path, label in ((("env",), "env"), (("container", "env"), "container env")):
            value = descend(job, *path)
            if value is not None:
                yield f"job `{key.text}` {label}", value


def check_env(check: Workflow, where: str, env: Node) -> None:
    """Deny the keys that could reach the mint from one ``env:``.

    Args:
        check: The workflow check.
        where: Where the ``env:`` is, for the message.
        env: The ``env:`` value node.
    """
    if env.kind != MAPPING:
        check.fail(
            env.line,
            "app",
            f"{where} must be a mapping in a reusable that takes the tooling App "
            "credential; an expression could hand the mint an INPUT_ variable",
        )
        return
    for key, _ in env.pairs:
        name = key.text if key.kind == SCALAR else ""
        if key.kind == SCALAR and "${{" not in name and not AMBIENT_KEY.match(name):
            continue
        check.fail(
            key.line,
            "app",
            f"{where} may not set `{name or 'a non-scalar key'}`: the tooling App "
            "mint would read it (INPUT_* as an input, NODE_* and proxies in Node)",
        )


def mint_environment(root: Node | None, job: Node, mint: Node) -> set[str]:
    """Return the variable names the mint step's process starts with.

    Only what the workflow file decides: workflow, job and container
    ``env:`` keys and one ``INPUT_<NAME>`` per ``with:`` key, named as the
    runner names them. ``$GITHUB_ENV`` writes and action defaults are not
    included.

    Args:
        root: Root node of the workflow.
        job: The minting job.
        mint: The mint step.

    Returns:
        set[str]: The variable names.
    """
    names: set[str] = set()
    for env in (
        descend(root, "env"),
        descend(job, "env"),
        descend(job, "container", "env"),
    ):
        names.update(fields(env))
    for name in fields(descend(mint, "with")):
        names.add(f"INPUT_{name.replace(' ', '_').upper()}")
    return names


def check_step_before_mint(check: Workflow, step: Node) -> None:
    """Hold one step that runs before the check step to "no caller code".

    Args:
        check: The workflow check.
        step: The step mapping.
    """
    entries = fields(step)
    label = descend(step, "name") or descend(step, "id")
    shown = f"line {step.line}"
    if label is not None and label.kind == SCALAR:
        shown = label.text
    env = descend(step, "env")
    if env is not None:
        check_env(check, f"step `{shown}` `env:`", env)
    if "working-directory" in entries:
        check.fail(
            step.line,
            "app",
            f"step `{shown}` runs before the tooling App mint and may not set "
            "`working-directory`",
        )
    uses = descend(step, "uses")
    pinned = uses is not None and uses.kind == SCALAR
    pinned = pinned and REMOTE_PINNED.fullmatch(uses.text.strip()) is not None
    if uses is not None and not pinned:
        check.fail(
            uses.line,
            "app",
            f"step `{shown}` runs before the tooling App mint: it must use a remote "
            "action pinned to a full commit, not a local or container action",
        )
    run = descend(step, "run")
    if run is None or (run.kind == SCALAR and GENERATED.match(run.text)):
        return
    found = CALLER_CODE.search(run.text) if run.kind == SCALAR else None
    if run.kind != SCALAR or found:
        what = f"`{found.group(0).strip()}`" if found else "a non-text script"
        check.fail(
            run.line,
            "app",
            f"step `{shown}` runs before the tooling App mint and its `run:` has "
            f"{what}; no caller code, $GITHUB_ENV write or INPUT_ text may run there",
        )


def check_ambient(check: Workflow, minting: list[tuple[Node, int]]) -> None:
    """Apply the ambient rule to a file that takes the pair.

    Args:
        check: The workflow check.
        minting: Each minting job's steps sequence and the check step's index.
    """
    for where, env in env_mappings(check.root):
        check_env(check, where, env)
    for steps, target in minting:
        for step in steps.items[:target]:
            check_step_before_mint(check, step)
