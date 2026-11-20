#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""What reaches the tooling App mint besides its own ``with:`` (#1622).

Used by ``tooling_app_credential.py`` for a reusable that takes the tooling
App credential. The minting action, ``actions/create-github-app-token`` at the
pinned commit, reads its inputs from the process environment: every variable
whose name starts with ``INPUT_PERMISSION-`` becomes a requested permission
(``lib/get-permissions-from-inputs.js``). The check step before it is a bash
script, and bash and the dynamic loader read their own variables. In a job
that mints, that environment can come only from the workflow and job
``env:`` (held to ``ENV_KEYS``) and from the steps before the mint (held to
the reviewed shapes); a job container is refused.

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
  the plain-name and loader-list rule (``refused_key`` with ``LOADER_NAMES``
  and ``LOADER_PREFIXES``).
- No ``defaults.run`` at workflow or job level: it would change the shell of
  a step before the mint. A job that mints has no ``container:``: options, an
  image's own ``ENV`` and expressions could all hand the mint an input, and
  no reusable runs one today. Services stay allowed; they are separate
  containers.
- Every step before the check step, in a job that mints, is one of the
  reviewed shapes: a ``uses:`` of an action named in ``PRE_MINT_ACTIONS``, at
  the one pin the repository uses for it, with no ``env:``; a ``run:`` that is
  exactly one generated block of an id in ``PRE_MINT_BLOCKS`` with that
  block's reviewed body and ``env:`` keys; or a ``run:`` that is exactly one
  script in ``PRE_MINT_SCRIPTS`` with its ``env:`` keys. Only ``shell: bash``
  or no ``shell:``, and no other key (``working-directory``,
  ``continue-on-error`` and ``timeout-minutes`` included). Anything else is
  refused, whatever its text says.

Pins. No pin is written in this file. The minting action's pin is read from
the block source ``scripts/ci/bootstrap/tooling-app-mint.yml``; for the other
listed actions, the accepted pin is the one every workflow in the checked
directory uses (``accepted_pins``), and more than one pin for an action is an
error. Renovate updates every copy of a pin in one pull request (the
``github-actions`` manager for workflows, a regex manager for the block
source, grouped by package name in ``renovate.json``), so a bump passes this
check without an edit here, and a single step pinned elsewhere does not.

What this cannot stop. A reviewed remote action runs code the check cannot
read; that is why the list names each action with its reason. Inside that
bound no caller code runs before the mint. The real limit on what a
token can hold is still the App's registration
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
from collections import Counter
from collections.abc import Iterator
from pathlib import Path
from typing import Protocol

from tooling_token_yaml import MAPPING, SCALAR, Node, descend, fields, parse

# The generated blocks live in scripts/ci/bootstrap/sync_inline_blocks.py.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bootstrap"))
import sync_inline_blocks  # noqa: E402  # pylint: disable=wrong-import-position

# Where the block sources are read from; tests point it at a scratch copy.
SOURCE_ROOT = sync_inline_blocks.ROOT
THIS_FILE = "scripts/ci/quality/tooling_app_ambient.py"
MINT_SOURCE = "scripts/ci/bootstrap/tooling-app-mint.yml"
MINT_NAME = "actions/create-github-app-token"

# A plain variable name; anything else could be a loader trick or an input.
PLAIN_KEY = re.compile(r"[A-Z_][A-Z0-9_]*")
# The narrower rule for the env: of a job that does not mint (a minting job
# is held to ENV_KEYS): names read by bash, the dynamic loader, Node or its
# TLS and proxy code, which could run code or redirect a request.
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
    "LGTM_CI_EGRESS_RESULTS_STORAGE": "generated results storage hosts (harden-runner)",
    "LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS": "generated: presets using that storage",
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

# Actions that may run before the mint, by name; the pin is not written here
# (see "Pins" above).
PRE_MINT_ACTIONS = {
    "step-security/harden-runner": "the egress block and its agent come first",
    "actions/checkout": "the caller checkout; it runs nothing it fetches",
    MINT_NAME: "the release App mint, which release jobs need before their tooling",
}
PINNED_USES = re.compile(r"""uses:\s*['"]?([\w.-]+/[\w./-]+)@([0-9a-f]{40})""")
# Generated blocks that may run before the mint, with their env: keys.
PRE_MINT_BLOCKS = {
    # LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT: the #1668 opt-in from vars.
    "verify-harden-runner-agent": frozenset(
        {
            "EGRESS_POLICY",
            "REPOSITORY_PRIVATE",
            "LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT",
        },
    ),
    "fail-unknown-egress-preset": frozenset({"EGRESS_PRESET"}),
    "select-app-credential": frozenset({"APP_ID", "APP_CLIENT_ID"}),
}


def _pipeline_skip() -> str:
    """Return the notice the Python test job prints for a skipped pipeline."""
    head = 'echo "Pipeline-irrelevant pull request; '
    return head + 'dependency installation and tests skipped."'


# Hand-written scripts that may run before the mint, exactly, with their
# env: keys. Each only prints a message and exits.
PRE_MINT_SCRIPTS = {
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
    path: Path

    def fail(self, line: int, rule: str, message: str) -> None:
        """Record a violation."""


def refused_key(name: str) -> bool:
    """Tell whether a key is refused in the ``env:`` of a job that does not mint.

    A minting job and the workflow ``env:`` are held to ``ENV_KEYS`` instead.

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
            "only the names on the reviewed list may reach the tooling App mint; "
            f"if this one is safe, add it with its reason to ENV_KEYS in {THIS_FILE}"
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
        str: The markers around the reviewed source body and its header.
    """
    body = sync_inline_blocks.generated_body(block_id, root=SOURCE_ROOT)
    begin = f"# lgtm-ci-inline:begin {block_id}"
    end = f"# lgtm-ci-inline:end {block_id}"
    return "\n".join([begin, *body, end]) + "\n"


def mint_uses() -> str:
    """Return the minting action and pin, as the block source writes them.

    Returns:
        str: ``actions/create-github-app-token@<sha>`` from ``MINT_SOURCE``.
    """
    lines = sync_inline_blocks.source_body("tooling-app-mint", root=SOURCE_ROOT)
    body = "\n".join(lines)
    steps = parse(body)[0]
    mint = steps.items[-1] if steps is not None else None
    uses = descend(mint, "uses")
    return uses.text.strip() if uses is not None else ""


def accepted_pins(directory: Path) -> dict[str, Counter[str]]:
    """Count every pin of each listed action in a workflows directory.

    The minting action's pin in ``MINT_SOURCE`` counts too, so a release mint
    before the tooling mint must use the same commit.

    Args:
        directory: The workflows directory under check.

    Returns:
        dict[str, Counter[str]]: How often each commit is used, per listed
        action name.
    """
    pins: dict[str, Counter[str]] = {name: Counter() for name in PRE_MINT_ACTIONS}
    paths = [*directory.glob("*.yml"), *directory.glob("*.yaml")]
    texts = [path.read_text(encoding="utf-8", errors="replace") for path in paths]
    texts.append(f"uses: {mint_uses()}")
    for text in texts:
        for name, pin in PINNED_USES.findall(text):
            if name in pins:
                pins[name][pin] += 1
    return pins


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


def uses_problem(uses: Node, pins: dict[str, Counter[str]]) -> str:
    """Tell why a ``uses:`` step before the mint is not a reviewed shape.

    A listed action passes only when its ref is a full commit SHA and that
    commit is the one and only pin the repository uses for it: a branch, a
    tag or a commit used nowhere else is refused.

    Args:
        uses: The step's ``uses`` value node.
        pins: The commits in use per listed action (``accepted_pins``).

    Returns:
        str: The reason, naming what was found and what to edit, or an empty
        string for a listed action at the repository's one pin.
    """
    found = uses.text.strip() if uses.kind == SCALAR else f"a {uses.kind}"
    name = found.partition("@")[0]
    if name not in PRE_MINT_ACTIONS:
        accepted = ", ".join(
            f"{action}@{commit}"
            for action, commits in sorted(pins.items())
            for commit in sorted(commits)
        )
        return (
            f"it uses `{found}`, which is not an action PRE_MINT_ACTIONS in "
            f"{THIS_FILE} allows before the mint (accepted: {accepted})"
        )
    ref = found.partition("@")[2]
    if len(pins[name]) == 1 and ref in pins[name]:
        return ""
    if len(pins[name]) <= 1:
        expected = ", ".join(f"{name}@{commit}" for commit in pins[name]) or "none"
        return (
            f"it uses `{found}`, but before the mint {name} must be pinned at "
            f"the full commit the repository uses for it (found: {expected})"
        )
    common = pins[name].most_common()
    counts = ", ".join(f"{commit} x{count}" for commit, count in common)
    return (
        f"it uses `{found}`, but the repository pins `{name}` at more than one "
        f"commit ({counts}); every copy must be the same commit, as a Renovate "
        f"bump leaves them (for {MINT_NAME} the source is {MINT_SOURCE})"
    )


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
        return (
            "its `run:` is not exactly a reviewed generated block (PRE_MINT_BLOCKS) "
            f"or script (PRE_MINT_SCRIPTS) in {THIS_FILE}; a new one is added there "
            "with its env: keys"
        )
    found = env_keys(step)
    if found is None or frozenset(found) != allowed:
        return f"its `env:` keys are not exactly {sorted(allowed) or 'none'}"
    return ""


def shape_problem(step: Node, pins: dict[str, Counter[str]]) -> str:
    """Tell why a step before the mint is not a reviewed shape.

    Args:
        step: The step mapping.
        pins: The accepted commits per listed action (``accepted_pins``).

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
    return uses_problem(uses, pins) if uses is not None else run_problem(step)


def check_steps_before_mint(
    check: Workflow,
    steps: list[Node],
    pins: dict[str, Counter[str]],
) -> None:
    """Hold every step before the check step to a reviewed shape.

    Args:
        check: The workflow check.
        steps: The steps of a minting job before its check step.
        pins: The accepted commits per listed action (``accepted_pins``).
    """
    for step in steps:
        problem = shape_problem(step, pins)
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
    pins = accepted_pins(check.path.parent) if minting else {}
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
        check_steps_before_mint(check, steps.items[:target], pins)
