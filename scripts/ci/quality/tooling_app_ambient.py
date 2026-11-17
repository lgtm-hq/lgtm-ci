#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""What reaches the tooling App mint besides its own ``with:`` (#1622).

Used by ``tooling_app_credential.py`` for a reusable that takes the tooling
App credential. The minting action, ``actions/create-github-app-token`` at the
pinned commit, reads its inputs from the process environment: every variable
whose name starts with ``INPUT_PERMISSION-`` becomes a requested permission
(``lib/get-permissions-from-inputs.js``). The check step before it is a bash
script, and bash and the dynamic loader read their own variables. That
environment is built from the workflow and job ``env:``, a job container, and
whatever the steps before the mint did on the runner.

Rule ``app`` (ambient), in a file that takes the pair:

- Workflow ``env:`` and the ``env:`` of every job that mints: each must be a
  plain mapping, and each key must be on ``ENV_KEYS``, an explicit list with a
  reason per name, compared exactly. Nothing else is accepted, so a new key
  is one reviewed edit, as a new pinned action is. A deny-list cannot keep up:
  git (``GIT_CONFIG_*``, ``GIT_CONFIG_GLOBAL``) runs filters and hooks during
  the caller checkout, OpenSSL (``OPENSSL_CONF``, ``OPENSSL_MODULES``) loads
  modules into the mint's Node process, and ``HARDEN_RUNNER_*`` moves where
  the verification looks.
- The ``env:`` of a job that does not mint never reaches the mint; it keeps
  the plain-name and loader-list rule (``refused_key``).
- No ``defaults.run`` at workflow or job level: it would change the shell of
  a step before the mint. A job that mints has no ``container:``: options, an
  image's own ``ENV`` and expressions could all hand the mint an input, and
  no reusable runs one today. Services stay allowed; they are separate
  containers.
- Every step before the check step, in a job that mints, is one of the
  reviewed shapes: a ``uses:`` of an action and pin in ``PRE_MINT_ACTIONS``
  with no ``env:``; a ``run:`` that is exactly one generated block of an id in
  ``PRE_MINT_BLOCKS`` with that block's reviewed body and ``env:`` keys; or a
  ``run:`` that is exactly one script in ``PRE_MINT_SCRIPTS`` with its ``env:``
  keys. Only ``shell: bash`` or no ``shell:``, and no other key
  (``working-directory``, ``continue-on-error`` and ``timeout-minutes``
  included). Anything else is refused, whatever its text says.

What this cannot stop. A reviewed remote action runs code the check cannot
read; that is why the list names each action, pin and reason, and why a pin
bump is a reviewed edit here. Inside that bound no caller code runs before the
mint. The real limit on what a token can hold is still the App's registration
(Contents: Read-only, installed on the tooling repository only);
``permission-contents: read`` only narrows a token inside it.

``GITHUB_*`` and ``RUNNER_*`` keys are not refused: GitHub documents that a
workflow cannot overwrite the default variables with those names, and that
such an assignment is ignored ("Variables" reference, "Default environment
variables" and "Naming conventions for environment variables").
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Protocol

from tooling_token_yaml import MAPPING, SCALAR, Node, descend, fields

# The generated blocks live in scripts/ci/bootstrap/sync_inline_blocks.py.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bootstrap"))
import sync_inline_blocks  # noqa: E402  # pylint: disable=wrong-import-position

# A plain variable name; anything else could be a loader trick or an input.
PLAIN_KEY = re.compile(r"[A-Z_][A-Z0-9_]*")
# Read by bash, the dynamic loader, Node or its TLS and proxy code before or
# while the check step and the mint run, so they could run code or redirect
# the API call that carries the App's signed request.
LOADER_NAMES = frozenset(
    {
        "BASHOPTS",  # bash: options such as xtrace, with PS4 below
        "ENV",  # sh: a file sourced at start
        "GCONV_PATH",  # glibc: modules loaded for character conversion
        "IFS",  # bash: word splitting of every unquoted expansion
        "PATH",  # where `bash` and every command is found
        "PROMPT_COMMAND",  # bash: run before each prompt
        "PS4",  # bash: expanded, command substitutions included, under xtrace
        "SHELLOPTS",  # bash: options such as xtrace at start
        "SSL_CERT_DIR",  # TLS trust store for the API call
        "SSL_CERT_FILE",  # TLS trust store for the API call
        "HTTP_PROXY",  # where the API call goes
        "HTTPS_PROXY",  # where the API call goes
        "ALL_PROXY",  # where the API call goes
        "NO_PROXY",  # which hosts skip the proxy
    },
)
LOADER_PREFIXES = (
    "BASH_",  # BASH_ENV (sourced by every bash step), BASH_FUNC_* (functions)
    "DYLD_",  # macOS loader: libraries injected into every process
    "INPUT_",  # read by the action as its inputs, permissions included
    "LD_",  # Linux loader: LD_PRELOAD, LD_LIBRARY_PATH and the rest
    "NODE_",  # NODE_OPTIONS, NODE_EXTRA_CA_CERTS, NODE_PATH for the action
)

# The only keys a workflow env: or a minting job's env: may set, with why.
# Every other name is refused, whatever family it belongs to.
ENV_KEYS = {
    "LGTM_CI_EGRESS_PRESETS": "generated egress preset map read by harden-runner",
    "LGTM_CI_TOOLING_APP_ID_SET": "tooling App flag: is the client ID set",
    "LGTM_CI_TOOLING_APP_KEY_SET": "tooling App flag: is the private key set",
    "LGTM_CI_TOOLING_APP_NEEDED": "tooling App: will a tooling consumer run",
    # A Boolean the private-dependency steps read; git reads no such name.
    "GIT_DEPS_TOKEN_PRESENT": "test-python: is the dependency secret set",  # nosec B105
    "AI_REVIEW_PROVIDER": "ai-review: provider chosen from inputs or vars",
    "AI_REVIEW_TRANSPORT": "ai-review: transport chosen from inputs or vars",
    "AI_REVIEW_AUTH": "ai-review: auth mode chosen from inputs, vars or defaults",
    "AI_REVIEW_AUTH_SOURCE": "ai-review: where the auth mode came from",
    "LINTRO_IMAGE": "lint and audit jobs: the pinned lintro image input",
}

# Actions that may run before the mint, exactly as pinned in the workflows.
# A pin bump changes the text here, which a reviewer approves.
PRE_MINT_ACTIONS = {
    "step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43": (
        "the egress block and its agent must be in place first"
    ),
    "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1": (
        "the caller checkout; it runs nothing it fetches"
    ),
    "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510": (
        "the release App mint, which release jobs need before their tooling"
    ),
}
# Generated blocks that may run before the mint, with their env: keys.
PRE_MINT_BLOCKS = {
    "verify-harden-runner-agent": frozenset({"EGRESS_POLICY", "REPOSITORY_PRIVATE"}),
    "select-app-credential": frozenset({"APP_ID", "APP_CLIENT_ID"}),
}
# Hand-written scripts that may run before the mint, exactly, with their
# env: keys. Each only prints a message and exits.


def _unknown_preset() -> str:
    """Return the preset check every reusable runs before its tooling."""
    head = 'echo "::error title=unknown egress-preset::'
    return head + "not a preset - '${EGRESS_PRESET}'\"; exit 1"


def _pipeline_skip() -> str:
    """Return the notice the Python test job prints for a skipped pipeline."""
    head = 'echo "Pipeline-irrelevant pull request; '
    return head + 'dependency installation and tests skipped."'


PRE_MINT_SCRIPTS = {
    _unknown_preset(): frozenset({"EGRESS_PRESET"}),
    (
        "echo \"::error::Matrix preparation concluded '${PREPARE_RESULT}'; "
        'failing the check."\nexit 1\n'
    ): frozenset({"PREPARE_RESULT"}),
    (
        "echo \"::error::egress-policy 'block' cannot be enforced on GitHub-hosted "
        '${RUNNER_OS};" \\\n'
        '  "use a GitHub-hosted Linux runner-image or a self-hosted runner"\n'
        "exit 1\n"
    ): frozenset(),
    _pipeline_skip(): frozenset(),
}
USES_KEYS = frozenset({"name", "id", "if", "uses", "with"})
RUN_KEYS = frozenset({"name", "id", "if", "shell", "env", "run"})
BEGIN = re.compile(r"\A# lgtm-ci-inline:begin (\S+)\n")


class Workflow(Protocol):  # pylint: disable=too-few-public-methods
    """What these rules need from the workflow check that calls them."""

    root: Node | None

    def fail(self, line: int, rule: str, message: str) -> None:
        """Record a violation."""


def refused_key(name: str) -> bool:
    """Tell whether a workflow or job ``env:`` key could reach the mint.

    Args:
        name: The key as written.

    Returns:
        bool: True when it is not a plain name or is on the loader list.
    """
    upper = name.upper()
    plain = PLAIN_KEY.fullmatch(name) is not None
    return not plain or upper in LOADER_NAMES or upper.startswith(LOADER_PREFIXES)


def env_mappings(root: Node | None) -> Iterator[tuple[str, Node, Node | None]]:
    """Yield the workflow ``env:`` and every job ``env:``, with a label.

    Args:
        root: Root node of the workflow.

    Yields:
        tuple[str, Node, Node | None]: Where the ``env:`` is, its value node,
        and its job (None for the workflow ``env:``).
    """
    top = descend(root, "env")
    if top is not None:
        yield "workflow `env:`", top, None
    for key, job in fields(descend(root, "jobs")).values():
        value = descend(job, "env")
        if value is not None:
            yield f"job `{key.text}` env", value, job


def check_env(check: Workflow, where: str, env: Node, listed: bool) -> None:
    """Refuse the keys that could reach the check step or the mint.

    Args:
        check: The workflow check.
        where: Where the ``env:`` is, for the message.
        env: The ``env:`` value node.
        listed: Whether only ``ENV_KEYS`` may appear (the workflow and every
            minting job); otherwise the plain-name and loader rule applies.
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
        if listed and name in ENV_KEYS:
            continue
        if not listed and name and not refused_key(name):
            continue
        rule = (
            "only the names on the reviewed list (ENV_KEYS in "
            "tooling_app_ambient.py) may reach the tooling App mint"
            if listed
            else "only plain upper-case names off the loader list may be set"
        )
        shown = name or "a non-scalar key"
        check.fail(key.line, "app", f"{where} may not set `{shown}`: {rule}")


def check_defaults(check: Workflow) -> None:
    """Refuse ``defaults.run`` at workflow and job level.

    Args:
        check: The workflow check.
    """
    places = [("the workflow", check.root)]
    places += [
        (f"job `{key.text}`", job)
        for key, job in fields(descend(check.root, "jobs")).values()
        if key.kind == SCALAR
    ]
    for label, node in places:
        run = descend(node, "defaults", "run")
        if run is not None:
            check.fail(
                run.line,
                "app",
                f"{label} sets `defaults.run` in a reusable that takes the tooling "
                "App credential; it would change the shell of a step before the mint",
            )


def mint_environment(root: Node | None, job: Node, mint: Node) -> set[str]:
    """Return the variable names the mint step's process starts with.

    Only what the workflow file decides: workflow and job ``env:`` keys and
    one ``INPUT_<NAME>`` per ``with:`` key, named as the runner names them.

    Args:
        root: Root node of the workflow.
        job: The minting job.
        mint: The mint step.

    Returns:
        set[str]: The variable names.
    """
    names: set[str] = set()
    for env in (descend(root, "env"), descend(job, "env")):
        names.update(fields(env))
    for name in fields(descend(mint, "with")):
        names.add(f"INPUT_{name.replace(' ', '_').upper()}")
    return names


def block_text(block_id: str) -> str:
    """Return the exact ``run:`` text of one generated block.

    Args:
        block_id: A key of ``sync_inline_blocks.BLOCKS``.

    Returns:
        str: The markers around the reviewed source body.
    """
    body = sync_inline_blocks.source_body(block_id)
    begin = f"# lgtm-ci-inline:begin {block_id}"
    end = f"# lgtm-ci-inline:end {block_id}"
    return "\n".join([begin, *body, end]) + "\n"


def reviewed_run(run: str) -> frozenset[str] | None:
    """Return the ``env:`` keys a reviewed ``run:`` takes, or None.

    Args:
        run: The step's ``run:`` text.

    Returns:
        frozenset[str] | None: None when the text is neither an exact
        reviewed block nor an exact reviewed script.
    """
    begin = BEGIN.match(run)
    if begin is not None:
        block_id = begin.group(1)
        if block_id in PRE_MINT_BLOCKS and run == block_text(block_id):
            return PRE_MINT_BLOCKS[block_id]
        return None
    return PRE_MINT_SCRIPTS.get(run)


def env_keys(step: Node) -> set[str] | None:
    """Return a step's ``env:`` keys, or None when it is not a plain mapping."""
    env = descend(step, "env")
    if env is None:
        return set()
    if env.kind != MAPPING or any(key.kind != SCALAR for key, _ in env.pairs):
        return None
    return set(fields(env))


def uses_problem(uses: Node) -> str:
    """Tell why a ``uses:`` step before the mint is not a reviewed shape.

    Args:
        uses: The step's ``uses`` value node.

    Returns:
        str: The reason, or an empty string for a listed action and pin.
    """
    if uses.kind == SCALAR and uses.text.strip() in PRE_MINT_ACTIONS:
        return ""
    return "its action and pin are not on the list that may run first"


def run_problem(step: Node) -> str:
    """Tell why a ``run:`` step before the mint is not a reviewed shape.

    Args:
        step: The step mapping.

    Returns:
        str: The reason, or an empty string for a reviewed block or script
        with exactly its ``env:`` keys.
    """
    run = descend(step, "run")
    allowed = reviewed_run(run.text) if run is not None and run.kind == SCALAR else None
    if allowed is None:
        return "its `run:` is not exactly a reviewed generated block or script"
    found = env_keys(step)
    if found is None or frozenset(found) != allowed:
        return f"its `env:` keys are not exactly {sorted(allowed) or 'none'}"
    return ""


def shape_problem(step: Node) -> str:
    """Tell why a step before the mint is not a reviewed shape.

    Args:
        step: The step mapping.

    Returns:
        str: The reason, or an empty string for a reviewed shape.
    """
    shell = descend(step, "shell")
    if shell is not None and (shell.kind, shell.text) != (SCALAR, "bash"):
        return "its `shell:` is not `bash`"
    uses = descend(step, "uses")
    allowed_keys = USES_KEYS if uses is not None else RUN_KEYS
    extra = sorted(set(fields(step)) - allowed_keys)
    if extra:
        return f"it sets `{extra[0]}`"
    return uses_problem(uses) if uses is not None else run_problem(step)


def check_steps_before_mint(check: Workflow, steps: list[Node]) -> None:
    """Hold every step before the check step to a reviewed shape.

    Args:
        check: The workflow check.
        steps: The steps of a minting job before its check step.
    """
    for step in steps:
        problem = shape_problem(step)
        if not problem:
            continue
        label = descend(step, "name") or descend(step, "id")
        shown = f"line {step.line}"
        if label is not None and label.kind == SCALAR:
            shown = label.text
        check.fail(
            step.line,
            "app",
            f"step `{shown}` runs before the tooling App mint and is not a reviewed "
            f"shape: {problem}",
        )


def check_ambient(check: Workflow, minting: list[tuple[Node, Node, int]]) -> None:
    """Apply the ambient rule to a file that takes the pair.

    Args:
        check: The workflow check.
        minting: Each minting job, its steps sequence and the check step's
            index.
    """
    minting_jobs = {id(job) for job, _, _ in minting}
    for where, env, job in env_mappings(check.root):
        check_env(check, where, env, job is None or id(job) in minting_jobs)
    check_defaults(check)
    for job, steps, target in minting:
        container = fields(job).get("container")
        if container is not None:
            check.fail(
                container[0].line,
                "app",
                "a job that mints the tooling App token may not run in a "
                "`container:`; its options, image and expressions could hand the "
                "mint an input",
            )
        check_steps_before_mint(check, steps.items[:target])
