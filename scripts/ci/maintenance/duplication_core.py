# SPDX-License-Identifier: MIT
"""Lossy operation identities used exclusively for manual catalog review.

These tokens deliberately do not affect exact shapes, fingerprints or issues.
One token represents one top-level core step; composites are not expanded.
"""

from __future__ import annotations

import hashlib
import re
import shlex
from pathlib import PurePosixPath
from typing import Any

INPUT = re.compile(r"\$\{\{\s*inputs\.([\w-]+)\s*\}\}")
VARIABLE = re.compile(r"\$\{(\w+)\}|\$(\w+)")
INFRASTRUCTURE = {
    "actions/checkout",
    "step-security/harden-runner",
    "actions/upload-artifact",
    "actions/download-artifact",
    "lgtm-ci/checkout-and-harden",
}
SCRIPT_ROLES = {
    "security-audit.sh": "security-audit",
    "run-lintro-audit.sh": "security-audit",
}
INTERPRETERS = {"bash", "sh", "python", "python3", "node"}
QUOTED_MESSAGE = r"""(?:"[^"\n]*"|'[^'\n]*')"""


def mapping(value: Any) -> dict[str, Any]:
    """Reject malformed mappings through the existing invalid-source contract."""
    if not isinstance(value, dict):
        raise ValueError("invalid operation context mapping")
    return value


def action_identity(target: str) -> str:
    """Drop refs and recognize local/vendored lgtm-ci action entry points."""
    target = target.split("@", 1)[0].lower()
    for prefix in (
        "./.github/actions/",
        "./.lgtm-ci-tooling/.github/actions/",
        "lgtm-hq/lgtm-ci/.github/actions/",
    ):
        if target.startswith(prefix):
            return "lgtm-ci/" + target.removeprefix(prefix)
    return target


def resolve(value: Any, inputs: dict[str, Any]) -> str:
    """Substitute only direct input expressions with declared literal defaults."""
    return INPUT.sub(
        lambda match: str(inputs.get(match[1], {}).get("default", match[0])),
        str(value),
    )


def expand_environment(source: str, environment: dict[str, Any]) -> str:
    """Substitute direct environment references once, without evaluation."""
    return VARIABLE.sub(
        lambda match: str(environment.get(match[1] or match[2], match[0])),
        source.strip(),
    )


def command_words(source: str) -> list[str]:
    """Read words conservatively; malformed quoting remains opaque."""
    try:
        return shlex.split(source, comments=True)
    except ValueError:
        return []


def run_operation(source: str, environment: dict[str, Any]) -> str:
    """Recognize a single script invocation; retain opaque blocks as digests."""
    source = expand_environment(source, environment)
    words = command_words(source)
    if words and not re.search(r"[\n;|&<>`]", source):
        if words[0] in INTERPRETERS:
            words = words[1:]
        if words and re.fullmatch(r"[\w./$-]+\.(?:sh|py|js|mjs)", words[0]):
            basename = PurePosixPath(words[0]).name
            operation = "script:" + SCRIPT_ROLES.get(basename, basename)
            selector = environment.get("STEP", "")
            return operation + (f":{selector}" if selector else "")
        if words and all(re.fullmatch(r"[\w./=-]+", word) for word in words):
            # Literal command/subcommand heads remain distinct (npm test/build).
            return "command:" + " ".join(words)
    return "opaque:" + hashlib.sha256(source.encode()).hexdigest()


def excluded(step: dict[str, Any], action: str) -> bool:
    """Remove only known whole infrastructure bodies, preserving extra work."""
    if action in INFRASTRUCTURE:
        return True
    source = str(step.get("run", "")).strip()
    name = str(step.get("name", "")).lower()
    if "$(" in source or "`" in source:
        return False
    warning = re.fullmatch(rf"(?:echo|printf)[ \t]+{QUOTED_MESSAGE}", source)
    egress = re.fullmatch(rf"echo[ \t]+{QUOTED_MESSAGE}[ \t]*[;\n][ \t]*exit 1", source)
    words = command_words(source)
    return (
        "egress-preset" in name
        and bool(re.search(r"\$(?:EGRESS_PRESET\b|\{EGRESS_PRESET\})", source))
        and bool(egress)
        and bool(words)
        or bool(warning)
        and len(words) == 2
        and words[1].startswith("::warning::")
        and ("upload" in name or "artifact" in name)
    )


def primary_step(step: dict[str, Any], environment: dict[str, Any]) -> bool:
    """Trace direct input provenance only through the executed script operand."""
    if step.get("uses"):
        return bool(INPUT.search(str(mapping(step.get("with", {})).get("file", ""))))
    source = expand_environment(str(step.get("run", "")), environment)
    # Keep direct expressions as one word before resolving their defaults.
    source = INPUT.sub(lambda match: "${{inputs." + match[1] + "}}", source)
    words = command_words(source)
    if words and words[0] in INTERPRETERS:
        words = words[1:]
    script_inputs = {
        match[1]
        for match in INPUT.finditer(words[0] if words else "")
        if match[1] == "script"
        or match[1].endswith("-script")
        and not match[1].startswith(("fail-", "setup-", "pre-", "post-"))
    }
    return bool(script_inputs)


def operations(
    document: dict[Any, Any],
    block: dict[str, Any],
) -> tuple[tuple[str, ...], str]:
    """Extract ordered core steps and the last deterministically primary step."""
    trigger = document.get("on", document.get(True, {}))
    call = {}
    if isinstance(trigger, dict):
        call = mapping(trigger.get("workflow_call", {}))
    inputs = mapping(call.get("inputs", {}))
    for value in inputs.values():
        mapping(value)
    environment = {
        **mapping(document.get("env", {})),
        **mapping(block.get("env", {})),
    }
    core: list[str] = []
    main = ""
    for step in block["steps"]:
        raw_env = {**environment, **mapping(step.get("env", {}))}
        parameters = mapping(step.get("with", {}))
        action = action_identity(str(step.get("uses", "")))
        if excluded(step, action):
            continue
        if action:
            operation = "action:" + action
            # Marker defines a comment's role; test/coverage comments cannot
            # become security-comment candidates solely by sharing this action.
            if action == "lgtm-ci/post-pr-comment":
                operation += ":" + resolve(parameters.get("marker", ""), inputs)
        else:
            operation = run_operation(
                resolve(step.get("run", ""), inputs),
                {key: resolve(value, inputs) for key, value in raw_env.items()},
            )
        core.append(operation)
        if (action or operation.startswith("script:")) and primary_step(step, raw_env):
            main = operation
    if "script:security-audit" in core:
        # Authentication and pre-pulling are the same preparation role only
        # inside an audit job, never a global equivalence for Docker operations.
        preparation = dict.fromkeys(
            {"action:docker/login-action", "script:pull-lintro-image.sh"},
            "role:prepare-audit-container",
        )
        core = [preparation.get(item, item) for item in core]
        main = preparation.get(main, main)
    return tuple(core), main
