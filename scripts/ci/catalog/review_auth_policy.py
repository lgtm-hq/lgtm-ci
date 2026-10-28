#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Inspect caller source expressions; encrypted slot values cannot prove provenance."""

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
    rows: list[list[str]],
) -> list[ReviewAuthSelector]:
    """Resolve each component without treating unreadable variables as absent."""
    config = passed if isinstance(passed, dict) else {}
    selection = []
    for key in ("provider", "transport", "auth"):
        value = config.get(key)
        variable = source_name(expression=value, context="vars")
        source = SelectorSource.INPUT
        if variable or not value:
            source = SelectorSource.VARIABLE
            if variables is None:
                source = SelectorSource.UNVERIFIED
                value = ""
            else:
                value = variables.get(variable.upper()) if variable else None
                value = value or variables.get(f"LINTRO_AI_{key.upper()}", "")
        elif "${{" in str(value):
            source = SelectorSource.UNVERIFIED
        selection.append(ReviewAuthSelector(value=str(value or ""), source=source))
    if not selection[2].value and selection[2].source != SelectorSource.UNVERIFIED:
        pair = [item.value for item in selection[:2]]
        if any(item.source == SelectorSource.UNVERIFIED for item in selection[:2]):
            selection[2] = ReviewAuthSelector(
                value="",
                source=SelectorSource.UNVERIFIED,
            )
        else:
            default = next(
                (row[2] for row in rows if row[:2] == pair and row[3] == "yes"),
                "",
            )
            selection[2] = ReviewAuthSelector(
                value=default,
                source=SelectorSource.VARIABLE,
            )
    return selection


def unverified_findings(
    selection: list[ReviewAuthSelector],
    secrets: Any,
    rows: list[list[str]],
    variables_readable: bool,
) -> set[str]:
    """Accept a possible credential slot while recording selection uncertainty."""
    mapping = secrets if isinstance(secrets, dict) else {}
    detail = "dynamic caller selectors"
    if not variables_readable:
        detail = "Actions variables unreadable"
    forwarded = "inherit" if secrets == "inherit" else ", ".join(sorted(mapping))
    result = {
        f"unverified: auth selection unverified: {detail}; "
        f"caller forwards {forwarded or 'no slots'}",
    }
    possible_slots = {
        candidate[4]
        for candidate in rows
        if all(
            item.source == SelectorSource.UNVERIFIED or item.value == value
            for item, value in zip(selection, candidate[:3], strict=True)
        )
    }
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
    selection = resolve_selection(passed=passed, variables=variables, rows=rows)
    unverified = any(item.source == SelectorSource.UNVERIFIED for item in selection)
    values = [item.value for item in selection]
    row = next((row for row in rows if not unverified and row[:3] == values), None)
    result: set[str] = set()
    if row is None and not unverified:
        detail = "Actions-variable/config inspection"
        result.add(f"unverified: review auth selectors require {detail}")
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
