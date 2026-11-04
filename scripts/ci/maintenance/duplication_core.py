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


def optional_mapping(value: Any) -> dict[str, Any]:
    """Treat a null optional mapping as empty, keeping definitions strict."""
    return mapping({} if value is None else value)


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


def expand_environment(source: str, environment: dict[str, Any]) -> str | None:
    """Expand a small shell subset with quote context, never evaluating source.

    Unquoted values requiring splitting or globbing remain opaque. Expansion
    values are data, so their quotes and dollar signs cannot become shell syntax.
    """
    result: list[str] = []
    quote = ""
    index = 0
    while index < len(source):
        char = source[index]
        if char == "\\" and quote != "'":
            result.append(source[index : index + 2])
            index += 2
            continue
        if char in ("'", '"') and (not quote or char == quote):
            quote = "" if quote else char
        if char == "$" and quote != "'":
            match = VARIABLE.match(source, index)
            if not match:
                return None
            name = match[1] or match[2]
            # The workspace root does not affect the script basename identity.
            value = environment.get(name, "." if name == "GITHUB_WORKSPACE" else None)
            if value is None:
                return None
            value = str(value)
            if quote == '"':
                value = re.sub(r'([\\"$`])', r"\\\1", value)
            elif not re.fullmatch(r"[\w./-]+", value):
                return None
            result.append(value)
            index = match.end()
            continue
        result.append(char)
        index += 1
    return "".join(result).strip()


def command_words(source: str) -> list[str]:
    """Read words conservatively; malformed quoting remains opaque."""
    try:
        return shlex.split(source, comments=True)
    except ValueError:
        return []


def run_operation(source: str, environment: dict[str, Any]) -> str:
    """Recognize a single script invocation; retain opaque blocks as digests."""
    expanded = expand_environment(source, environment)
    words = command_words(expanded) if expanded is not None else []
    source = expanded if expanded is not None else source
    if words and not re.search(r"[\n;|&<>`]", source):
        if words[0] in INTERPRETERS:
            words = words[1:]
        if words and re.fullmatch(r"[\w./-]+\.(?:sh|py|js|mjs)", words[0]):
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


def primary_step(
    step: dict[str, Any],
    environment: dict[str, Any],
    inputs: dict[str, Any],
) -> bool:
    """Trace direct input provenance only through the executed script operand."""
    if step.get("uses"):
        operand = optional_mapping(step.get("with", {})).get("file", "")
        if not isinstance(operand, str) or not INPUT.search(operand):
            return False
        for match in INPUT.finditer(operand):
            default = inputs.get(match[1], {}).get("default")
            if not isinstance(default, str) or not re.fullmatch(r"[\w./-]+", default):
                return False
        return bool(re.fullmatch(r"[\w./-]+", resolve(operand, inputs)))

    # Actions substitutes direct expressions before shell parsing, even inside
    # single quotes. Environment variables expand later under shell quoting.
    def provenance(value: Any) -> str:
        return INPUT.sub(lambda match: "__lgtm_input_" + match[1] + "__", str(value))

    source = expand_environment(
        provenance(step.get("run", "")),
        {key: provenance(value) for key, value in environment.items()},
    )
    words = command_words(source) if source is not None else []
    if words and words[0] in INTERPRETERS:
        words = words[1:]
    script_inputs = {
        match[1]
        for match in re.finditer(r"__lgtm_input_([\w-]+?)__", words[0] if words else "")
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
        call = optional_mapping(trigger.get("workflow_call", {}))
    inputs = optional_mapping(call.get("inputs", {}))
    for value in inputs.values():
        mapping(value)
    environment = {
        **optional_mapping(document.get("env", {})),
        **optional_mapping(block.get("env", {})),
    }
    core: list[str] = []
    main = ""
    for step in block["steps"]:
        raw_env = {**environment, **optional_mapping(step.get("env", {}))}
        parameters = optional_mapping(step.get("with", {}))
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
        if (action or operation.startswith("script:")) and primary_step(
            step,
            raw_env,
            inputs,
        ):
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
