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


def run_operation(source: str, environment: dict[str, Any]) -> str:
    """Recognize a single script invocation; retain opaque blocks as digests."""
    source = VARIABLE.sub(
        lambda match: str(environment.get(match[1] or match[2], match[0])),
        source.strip(),
    )
    try:
        words = shlex.split(source, comments=True)
    except ValueError:
        words = []
    if words and not re.search(r"[\n;|&<>`]", source):
        if words[0] in {"bash", "sh", "python", "python3", "node"}:
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
    """Remove checkout/hardening, artifacts, egress validation and warnings."""
    if action in INFRASTRUCTURE:
        return True
    source = str(step.get("run", ""))
    name = str(step.get("name", "")).lower()
    return (
        "egress-preset" in name
        and "EGRESS_PRESET" in source
        or "::warning::" in source
        and ("upload" in name or "artifact" in name)
        and source.strip().startswith(("echo ", "printf "))
    )


def primary_step(step: dict[str, Any]) -> bool:
    """Main consumes a script input (excluding helpers) or a file action input."""
    values = [str(step.get("run", "")), *map(str, (step.get("env") or {}).values())]
    script_inputs = {
        match[1]
        for value in values
        for match in INPUT.finditer(value)
        if match[1] == "script"
        or match[1].endswith("-script")
        and not match[1].startswith(("fail-", "setup-", "pre-", "post-"))
    }
    return bool(
        step.get("run")
        and script_inputs
        or step.get("uses")
        and INPUT.search(str((step.get("with") or {}).get("file", "")))
    )


def operations(
    document: dict[str, Any],
    block: dict[str, Any],
) -> tuple[tuple[str, ...], str]:
    """Extract ordered core steps and the last deterministically primary step."""
    trigger = document.get("on", document.get(True, {}))
    call = trigger.get("workflow_call", {}) if isinstance(trigger, dict) else {}
    inputs = call.get("inputs", {}) if isinstance(call, dict) else {}
    environment = {**(document.get("env") or {}), **(block.get("env") or {})}
    core: list[str] = []
    main = ""
    for step in block["steps"]:
        action = action_identity(str(step.get("uses", "")))
        if excluded(step, action):
            continue
        if action:
            operation = "action:" + action
            # Marker defines a comment's role; test/coverage comments cannot
            # become security-comment candidates solely by sharing this action.
            if action == "lgtm-ci/post-pr-comment":
                marker = resolve((step.get("with") or {}).get("marker", ""), inputs)
                operation += ":" + marker
        else:
            env = {
                key: resolve(value, inputs)
                for key, value in {
                    **environment,
                    **(step.get("env") or {}),
                }.items()
            }
            operation = run_operation(resolve(step.get("run", ""), inputs), env)
        core.append(operation)
        if primary_step(step) and (action or operation.startswith("script:")):
            main = operation
    if "script:security-audit" in core:
        # Authentication and pre-pulling are the same preparation role only
        # inside an audit job, never a global equivalence for Docker operations.
        core = [
            (
                "role:prepare-audit-container"
                if item in {"action:docker/login-action", "script:pull-lintro-image.sh"}
                else item
            )
            for item in core
        ]
    return tuple(core), main
