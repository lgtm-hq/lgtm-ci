#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Constructors for the ``comment.v1`` model (#1678).

The model (``schemas/comment.v1.json``) holds the facts of one comment
before layout; ``comment_format.py`` lays it out. A renderer builds it with
these functions, so every renderer writes the same shapes: the test report
(``comment_test_report.py``) now, the coverage, lint and link-check comments
in later slices of #1678. Every string passed here is raw text; nothing is
escaped until the formatter places it.

Standard library only and Python 3.10 compatible.
"""

from __future__ import annotations

from typing import Any

#: The value of every model's ``schema`` property.
SCHEMA = "comment.v1"
#: Status levels; anything but ``passed`` opens compact's details.
LEVELS = ("passed", "failed", "warning", "neutral")


def span(text: str, *, strong: bool = False, code: bool = False) -> dict[str, Any]:
    """Return a span: text in a headline group or a notice, bold or code."""
    made: dict[str, Any] = {"text": text}
    if strong:
        made["strong"] = True
    if code:
        made["code"] = True
    return made


def notice(*spans: dict[str, Any], emoji: str = "") -> dict[str, Any]:
    """Return a notice block: one paragraph of spans joined by spaces."""
    block: dict[str, Any] = {"type": "notice", "spans": list(spans)}
    if emoji:
        block["emoji"] = emoji
    return block


def column(label: str, *, right: bool = False, long_label: str = "") -> dict[str, Any]:
    """Return a table column; ``long_label`` stands in for a missing row label."""
    made: dict[str, Any] = {"label": label}
    if long_label:
        made["long_label"] = long_label
    if right:
        made["align"] = "right"
    return made


def table(
    table_id: str,
    title: str,
    columns: list[dict[str, Any]],
    rows: list[dict[str, Any]],
) -> dict[str, Any]:
    """Return a table block; each row is ``{"label": ..., "cells": [...]}``."""
    return {
        "type": "table",
        "id": table_id,
        "title": title,
        "columns": columns,
        "rows": rows,
    }


def fact(
    label: str,
    value: dict[str, Any],
    *,
    attach: str = "",
    colon: bool = False,
) -> dict[str, Any]:
    """Return a labelled fact; ``attach`` names the table it joins as a column."""
    made: dict[str, Any] = {"label": label, "value": value}
    if colon:
        made["colon"] = True
    if attach:
        made["attach"] = attach
    return made


def link(label: str, url: str, *, long_label: str = "") -> dict[str, Any]:
    """Return a link; ``long_label`` is its text in a footer."""
    made = {"label": label, "url": url}
    if long_label:
        made["long_label"] = long_label
    return made


def document(  # pylint: disable=too-many-arguments
    kind: str,
    *,
    title: dict[str, str],
    status: dict[str, str],
    summary: list[list[dict[str, Any]]],
    blocks: list[dict[str, Any]],
    facts: list[dict[str, Any]],
    links: list[dict[str, Any]],
    footer: str,
) -> dict[str, Any]:
    """Return a whole ``comment.v1`` document.

    Args:
        kind: Which comment, e.g. ``test-report``.
        title: ``{"icon": ..., "text": ...}``.
        status: ``{"level": ..., "emoji": ..., "label": ...}``; a level not in
            ``LEVELS`` becomes ``warning``, never ``passed``.
        summary: Headline groups of spans.
        blocks: Body blocks in order.
        facts: Labelled run facts.
        links: Links.
        footer: Small print at the end.

    Returns:
        The model.
    """
    level = status.get("level", "warning")
    return {
        "schema": SCHEMA,
        "kind": kind,
        "title": title,
        "status": {**status, "level": level if level in LEVELS else "warning"},
        "summary": summary,
        "blocks": blocks,
        "facts": facts,
        "links": links,
        "footer": footer,
    }
