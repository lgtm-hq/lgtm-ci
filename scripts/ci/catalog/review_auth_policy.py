#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Inspect caller source expressions; encrypted slot values cannot prove provenance."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

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


def findings(
    passed: Any,
    secrets: Any,
    variables: dict[str, str] | None = None,
) -> set[str]:
    """Check the selected credential and API-key provenance using known repo vars."""
    config = passed if isinstance(passed, dict) else {}
    keys = ("provider", "transport", "auth")
    selection = []
    for key in keys:
        value = config.get(key)
        variable = source_name(expression=value, context="vars")
        if variable and variables is not None:
            value = variables.get(variable.upper())
        value = value or (variables or {}).get(f"LINTRO_AI_{key.upper()}")
        selection.append(str(value or ""))
    rows = matrix_rows()
    if not selection[2]:
        selection[2] = next(
            (row[2] for row in rows if row[:2] == selection[:2] and row[3] == "yes"),
            "",
        )
    row = next((row for row in rows if row[:3] == selection), None)
    result: set[str] = set()
    if row is None:
        detail = "Actions-variable/config inspection"
        result.add(f"unverified: review auth selectors require {detail}")
    if secrets == "inherit":
        if selection[2] == "api_key" and (row is None or row[4] in REVIEW_SOURCES):
            result.add(
                "error: api_key reviews require explicit review-source mappings; "
                "secrets: inherit is unsupported"
            )
        elif row is None:
            result.add(
                "unverified: inherit requires a confirmed OAuth tuple",
            )
        return result
    mapping = secrets if isinstance(secrets, dict) else {}
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
