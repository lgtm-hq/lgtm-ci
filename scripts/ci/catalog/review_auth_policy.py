#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Conservatively inspect caller auth selection and credential source expressions.

Each provider, transport, and auth component is either KNOWN(value, source),
represented by ReviewAuthSelector, or UNKNOWN, represented by None. Only nonempty
literal workflow inputs and readable, set Actions variables provide known values.
Empty/unset values, dynamic expressions, unreadable variables, and lookup errors
remain unknown; repository config and matrix defaults never establish knowledge.

Only known components filter the capability matrix. Any unknown component emits
an informational auth-selection-unverified note listing compatible tuples. A
forwarded credential for any compatible tuple suffices; no compatible credential
is an error. An exact missing-slot error requires all three components known;
a fully known unsupported tuple is also an error.
API-key source policy is checked separately: encrypted values cannot prove origin.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

from review_auth_selector import ReviewAuthSelector, SelectorSource

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
# Standalone script library is added to the search path above.
# pylint: disable-next=wrong-import-position
from ai_review_capabilities import matrix_rows  # noqa: E402

REVIEW_SOURCES = {
    "ANTHROPIC_API_KEY": "ANTHROPIC_REVIEW_API_KEY",
    "OPENAI_API_KEY": "OPENAI_REVIEW_API_KEY",
    "CODEX_API_KEY": "OPENAI_REVIEW_API_KEY",
}


def source_name(expression: Any, context: str = "secrets") -> str | None:
    """Recognize literal dotted/bracket context sources; do not guess expressions."""
    match = re.fullmatch(
        rf"\s*\$\{{\{{\s*{re.escape(context)}(?:\.([A-Za-z_][A-Za-z_0-9]*)|"
        r"\[['\"]([A-Za-z_][A-Za-z_0-9]*)['\"]\])\s*\}\}\s*",
        str(expression),
    )
    return (match[1] or match[2]) if match else None


def resolve_selection(
    passed: Any,
    variables: dict[str, str] | None,
) -> list[ReviewAuthSelector | None]:
    """Resolve each component to known input/variable evidence or unknown."""
    config = passed if isinstance(passed, dict) else {}
    selection: list[ReviewAuthSelector | None] = []
    for key in ("provider", "transport", "auth"):
        value = config.get(key)
        variable = source_name(expression=value, context="vars")
        source = SelectorSource.INPUT
        if variable or not value:
            source = SelectorSource.VARIABLE
            readable = variables or {}
            value = readable.get(variable.upper()) if variable else None
            value = value or readable.get(f"LINTRO_AI_{key.upper()}")
        known = isinstance(value, str) and bool(value.strip()) and "${{" not in value
        selection.append(
            ReviewAuthSelector(value=value, source=source) if known else None,
        )
    return selection


def unverified_findings(
    selection: list[ReviewAuthSelector | None],
    secrets: Any,
    rows: list[list[str]],
    variables_readable: bool,
) -> set[str]:
    """Accept a possible credential slot while recording selection uncertainty."""
    mapping = secrets if isinstance(secrets, dict) else {}
    detail = "unresolved caller selectors"
    if not variables_readable:
        detail = "Actions variables unreadable"
    forwarded = "inherit" if secrets == "inherit" else ", ".join(sorted(mapping))
    compatible = [
        candidate
        for candidate in rows
        if all(
            item is None or item.value == value
            for item, value in zip(selection, candidate[:3], strict=True)
        )
    ]
    tuples = ", ".join("/".join(candidate[:3]) for candidate in compatible)
    result = {
        f"unverified: auth selection unverified: {detail}; "
        f"caller forwards {forwarded or 'no slots'}; "
        f"compatible tuples: {tuples or 'none'}",
    }
    possible_slots = {candidate[4] for candidate in compatible}
    if secrets != "inherit" and not possible_slots.intersection(mapping):
        result.add(
            "error: caller forwards no credential for any possible review auth tuple",
        )
    return result


def findings(
    passed: Any,
    secrets: Any,
    variables: dict[str, str] | None = None,
) -> set[str]:
    """Check the selected credential and API-key provenance using known repo vars."""
    rows = matrix_rows()
    selection = resolve_selection(passed=passed, variables=variables)
    unverified = any(item is None for item in selection)
    values = [item.value if item is not None else None for item in selection]
    row = next((row for row in rows if not unverified and row[:3] == values), None)
    result: set[str] = set()
    if row is None and not unverified:
        result.add(
            "error: selected review tuple "
            + "/".join(str(value) for value in values)
            + " is unsupported",
        )
    mapping = secrets if isinstance(secrets, dict) else {}
    if unverified:
        result.update(
            unverified_findings(
                selection=selection,
                secrets=secrets,
                rows=rows,
                variables_readable=variables is not None,
            ),
        )
    if secrets == "inherit":
        if values[2] == "api_key" and (row is None or row[4] in REVIEW_SOURCES):
            result.add(
                "error: api_key reviews require explicit review-source mappings; "
                "secrets: inherit is unsupported"
            )
        elif row is None:
            result.add(
                "unverified: inherit requires a confirmed OAuth tuple",
            )
        return result
    if row and row[4] not in mapping:
        result.add(f"error: selected review slot {row[4]} is missing")
    for slot, expected in REVIEW_SOURCES.items():
        if slot not in mapping:
            continue
        source = source_name(mapping[slot])
        if source != expected:
            kind = "error" if source else "unverified"
            result.add(
                f"{kind}: {slot} must map secrets.{expected}; "
                + (f"found secrets.{source}" if source else "source is dynamic")
            )
    return result
