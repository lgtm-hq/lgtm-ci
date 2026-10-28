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
from ai_review_capabilities import matrix_rows  # noqa: E402

REVIEW_SOURCES = {
    "ANTHROPIC_API_KEY": "ANTHROPIC_REVIEW_API_KEY",
    "OPENAI_API_KEY": "OPENAI_REVIEW_API_KEY",
    "CODEX_API_KEY": "OPENAI_REVIEW_API_KEY",
}


def source_name(expression: Any) -> str | None:
    """Recognize literal dotted/bracket secret sources; do not guess dynamic sources."""
    match = re.fullmatch(
        r"\s*\$\{\{\s*secrets(?:\.([A-Za-z_][A-Za-z_0-9]*)|"
        r"\[['\"]([A-Za-z_][A-Za-z_0-9]*)['\"]\])\s*\}\}\s*",
        str(expression),
    )
    return (match[1] or match[2]) if match else None


def findings(passed: Any, secrets: Any) -> set[str]:
    """Report smoke mappings, unsupported inherit and statically unverified routing."""
    config = passed if isinstance(passed, dict) else {}
    keys = ("provider", "transport", "auth")
    provider, transport, auth = (config.get(key, "") for key in keys)
    rows = matrix_rows()
    if not auth:
        defaults = {"/".join(row[:2]): row[2] for row in rows if row[3] == "yes"}
        auth = defaults.get(f"{provider}/{transport}", "")
    row = next((row for row in rows if row[:3] == [provider, transport, auth]), None)
    result: set[str] = set()
    if row is None:
        detail = "Actions-variable/config inspection"
        result.add(f"unverified: review auth selectors require {detail}")
    if secrets == "inherit":
        if auth == "api_key":
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
    for slot, expected in REVIEW_SOURCES.items():
        if slot not in mapping:
            if row and row[4] == slot:
                result.add(f"error: selected review slot {slot} is missing")
            continue
        source = source_name(mapping[slot])
        if source != expected:
            kind = "error" if source else "unverified"
            result.add(
                f"{kind}: {slot} must map secrets.{expected}; "
                + (f"found secrets.{source}" if source else "source is dynamic")
            )
    return result
