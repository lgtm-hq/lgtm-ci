#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Turn a ``comment.v1`` model into pull request comment markdown (#1678).

A renderer fills the model (``schemas/comment.v1.json``) with the facts of
one comment; this module lays it out in a ``comment-format``:

- ``compact``: one headline line, then everything else in a "Details"
  section that is folded when the status is passed and open otherwise;
- ``table``: a heading with the status, then the tables with nothing folded
  but the long lists, and the links in the footer.

``classic`` is not laid out here: it is still each renderer's own markdown,
byte for byte as before. The ``comment-fields`` block is not in the model
either: the shared poster inserts it, in the style named by
``FIELDS_STYLES``, under the heading (``table``) or under the headline line
(``compact``).

Every string of the model is raw text. Each one goes through
``comment_sanitize`` in the mode that fits where it lands (``text``/``cell``
for prose and table cells, ``code`` for code spans, ``labelled_link`` for
links, ``html`` for a ``<summary>`` line), and counts are written by
``_count``. A list block keeps within ``LIST_BUDGET_BYTES``, measured after
sanitising, as the classic renderer's expected-failures list does (#1702).

Standard library only and Python 3.10 compatible: the publisher may run it on
a runner with Python 3.10 (``ubuntu-22.04``).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:  # python3 -I leaves scripts/ci/lib off sys.path
    sys.path.insert(0, _LIB_DIR)

# pylint: disable=wrong-import-position
import comment_sanitize  # noqa: E402

# pylint: enable=wrong-import-position

#: Formats this module lays out.
FORMATS = ("compact", "table")
#: Every accepted ``comment-format`` value; ``classic`` is the renderer's own.
ALL_FORMATS = ("classic", *FORMATS)
#: The ``comment-fields`` style that goes with each format.
FIELDS_STYLES = {"classic": "block", "compact": "compact", "table": "table"}
#: Characters of each list value shown (the document may keep more).
LIST_VALUE_CHARS = 200
#: Most bytes a list block may take, measured after sanitising (#1702).
LIST_BUDGET_BYTES = 20000
#: Most bytes of a row label. A row label repeats the title (a suite name
#: the headline shows in full); one that is longer, or that the sanitiser
#: has to escape, reads ``ROW_LABEL_FALLBACK`` instead, so a format never
#: grows with the name more than classic does.
ROW_LABEL_BYTES = 32
ROW_LABEL_FALLBACK = "this run"
_SEP = " · "


def _count(value: Any) -> str:
    """Render a whole number."""
    return str(int(value))


def _text(value: Any) -> str:
    """Render raw text as inert inline markdown."""
    text: str = comment_sanitize.text(str(value))
    return text


def _dashes(width: int) -> str:
    """Return ``width`` dashes for a table rule."""
    return "".join("-" for _ in range(width))


def _span(span: dict[str, Any]) -> str:
    """Render one span: text, a code span, either one bold."""
    raw = str(span.get("text", ""))
    value: str = comment_sanitize.text(raw)
    if span.get("code"):
        value = comment_sanitize.code(raw)
    return f"**{value}**" if span.get("strong") else value


def _spans(spans: list[dict[str, Any]], joiner: str) -> str:
    """Render spans joined by ``joiner`` (a constant of this module)."""
    if joiner == ", ":
        return ", ".join(_span(span) for span in spans)
    return " ".join(_span(span) for span in spans)


def _label(item: dict[str, Any], *, long: bool) -> str:
    """Return the raw label of a link or column: ``long_label`` when asked."""
    short = str(item.get("label", ""))
    return str(item.get("long_label", short)) if long else short


def _link(link: dict[str, Any], *, long: bool = False) -> str:
    """Render ``[label](url)``, or the URL as inert text when it is not safe."""
    label = _text(_label(link, long=long))
    linked: str = comment_sanitize.labelled_link(str(link.get("url", "")), label)
    return linked


def _cell(cell: dict[str, Any], fmt: str) -> str:
    """Render one table cell or fact value in ``fmt``."""
    if "count" in cell:
        value = _count(cell["count"])
    elif "link" in cell:
        value = _link(cell["link"])
    else:
        value = comment_sanitize.cell(str(cell.get("text", "")))
    mark = cell.get("mark", "")
    if mark and (cell.get("mark_in", "all") == "all" or fmt == "table"):
        value = f"{value} {comment_sanitize.cell(str(mark))}"
    if cell.get("strong"):
        value = f"**{value}**"
    return value


def _row_label(row: dict[str, Any]) -> str:
    """Return a row's label, or ``ROW_LABEL_FALLBACK`` (see there)."""
    raw = str(row.get("label", ""))
    label: str = comment_sanitize.cell(raw)
    if label != raw or len(label.encode("utf-8")) > ROW_LABEL_BYTES:
        return ROW_LABEL_FALLBACK
    return label


def _rule(column: dict[str, Any], width: int) -> str:
    """Return the rule under one header: dashes, right-aligned with a colon."""
    if column.get("align") == "right":
        return _dashes(max(width - 1, 3)) + ":"
    return _dashes(max(width, 3))


def _header(column: dict[str, Any], *, long: bool) -> str:
    """Return the sanitised header text of a column."""
    header: str = comment_sanitize.cell(_label(column, long=long))
    return header


def _fact_header(fact: dict[str, Any]) -> str:
    """Return the sanitised header of a fact shown as a column."""
    header: str = comment_sanitize.cell(str(fact.get("label", "")))
    return header


def _fact_rule(fact: dict[str, Any]) -> str:
    """Return the rule under a fact shown as a column."""
    return _dashes(len(_fact_header(fact)) + 2)


def _table(block: dict[str, Any], fmt: str, facts: list[dict[str, Any]]) -> str:
    """Render a table block; in the table format ``facts`` join as columns."""
    rows = block.get("rows", [])
    columns = block.get("columns", [])
    labelled = fmt == "compact" or len(rows) > 1
    headers = [_header(column, long=not labelled) for column in columns]
    pairs = zip(columns, headers, strict=False)
    rules = [_rule(column, len(head) + 2) for column, head in pairs]
    headers.extend(_fact_header(fact) for fact in facts)
    rules.extend(_fact_rule(fact) for fact in facts)
    if labelled:
        corner = ""
        if fmt == "compact":
            corner = comment_sanitize.cell(str(block.get("title", "")))
        headers.insert(0, corner)
        rules.insert(0, _dashes(max(len(corner) + 2, 2)))
    sections = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join(rules) + "|",
    ]
    for index, row in enumerate(rows):
        cells = [_cell(cell, fmt) for cell in row.get("cells", [])]
        if index == 0:
            cells.extend(_cell(fact["value"], fmt) for fact in facts)
        else:
            cells.extend("" for _ in facts)
        if labelled:
            cells.insert(0, _row_label(row))
        sections.append("| " + " | ".join(cells) + " |")
    return "\n".join(sections)


def _list_line(item: dict[str, Any]) -> str:
    """Return one list line: ``- `code`: text``, each value capped."""
    code = str(item.get("code", ""))
    line: str = "- " + comment_sanitize.code(code, max_chars=LIST_VALUE_CHARS)
    text = str(item.get("text", ""))
    reason = comment_sanitize.text(text, max_chars=LIST_VALUE_CHARS)
    if reason:
        line = f"{line}: {reason}"
    return line


def _list(block: dict[str, Any]) -> str:
    """Render a folded list within ``LIST_BUDGET_BYTES``; the rest is counted."""
    summary = comment_sanitize.html(str(block.get("summary", "")))
    sections = ["<details>", f"<summary>{summary}</summary>", ""]
    used = len("\n".join(sections).encode("utf-8"))
    items = block.get("items", [])
    shown = 0
    for item in items:
        line = _list_line(item)
        size = len(line.encode("utf-8")) + 1
        if used + size > LIST_BUDGET_BYTES:
            break
        sections.append(line)
        used += size
        shown += 1
    more = int(block.get("more", 0)) + len(items) - shown
    if more > 0:
        sections.append(f"- and {_count(more)} more")
    if block.get("note"):
        sections.extend(["", _text(block["note"])])
    sections.extend(["", "</details>"])
    return "\n".join(sections)


def _notice(block: dict[str, Any]) -> str:
    """Render a notice paragraph."""
    body = _spans(block.get("spans", []), " ")
    emoji = block.get("emoji", "")
    return f"{_text(emoji)} {body}" if emoji else body


def _block(block: dict[str, Any], fmt: str, facts: list[dict[str, Any]]) -> str:
    """Render one block of the body."""
    kind = block.get("type")
    if kind == "table":
        return _table(block, fmt, facts)
    if kind == "list":
        return _list(block)
    return _notice(block)


def _attached(model: dict[str, Any], block: dict[str, Any]) -> list[dict[str, Any]]:
    """Return the facts that join ``block`` in the table format."""
    if block.get("type") != "table":
        return []
    facts = model.get("facts", [])
    return [fact for fact in facts if fact.get("attach") == block.get("id")]


def _loose(model: dict[str, Any]) -> list[dict[str, Any]]:
    """Return the facts whose table is not in the model (a table of their own)."""
    blocks = model.get("blocks", [])
    ids = {block.get("id") for block in blocks if block.get("type") == "table"}
    return [fact for fact in model.get("facts", []) if fact.get("attach") not in ids]


def _title(model: dict[str, Any]) -> str:
    """Return the sanitised icon and title text."""
    title = model.get("title", {})
    return f"{_text(title.get('icon', ''))} {_text(title.get('text', ''))}"


def _headline(model: dict[str, Any]) -> str:
    """Return compact's headline: title, status, then the summary groups."""
    status = model.get("status", {})
    sections = [
        f"**{_title(model)}**",
        f"{_text(status.get('emoji', ''))} **{_text(status.get('label', ''))}**",
    ]
    sections.extend(_spans(group, ", ") for group in model.get("summary", []))
    return " · ".join(sections)


def _fact(fact: dict[str, Any]) -> str:
    """Return one fact of compact's facts line."""
    label = _text(fact.get("label", ""))
    value = _cell(fact.get("value", {}), "compact")
    return f"{label}: {value}" if fact.get("colon") else f"{label} {value}"


def _facts_line(model: dict[str, Any]) -> str:
    """Return compact's facts line, with the links after the facts."""
    sections = [_fact(fact) for fact in model.get("facts", [])]
    sections.extend(_link(link) for link in model.get("links", []))
    return " · ".join(sections)


def _compact(model: dict[str, Any]) -> str:
    """Lay the model out in the compact format."""
    passed = model.get("status", {}).get("level") == "passed"
    sections = [_headline(model), "", "<details>" if passed else "<details open>"]
    sections.extend(["<summary>Details</summary>", ""])
    for block in model.get("blocks", []):
        sections.extend([_block(block, "compact", []), ""])
    if model.get("facts") or model.get("links"):
        sections.extend([_facts_line(model), ""])
    footer = _text(model.get("footer", ""))
    sections.extend(["</details>", "", f"<sub>{footer}</sub>"])
    return "\n".join(sections)


def _table_format(model: dict[str, Any]) -> str:
    """Lay the model out in the table format."""
    status = model.get("status", {})
    state = f"{_text(status.get('emoji', ''))} {_text(status.get('label', ''))}"
    sections = [f"### {_title(model)}{_SEP}{state}"]
    for block in model.get("blocks", []):
        sections.extend(["", _block(block, "table", _attached(model, block))])
    loose = _loose(model)
    if loose:
        own = {"type": "table", "id": "facts", "columns": [], "rows": [{"cells": []}]}
        sections.extend(["", _table(own, "table", loose)])
    footer = [_link(link, long=True) for link in model.get("links", [])]
    footer.append(_text(model.get("footer", "")))
    small = " · ".join(footer)
    sections.extend(["", f"<sub>{small}</sub>"])
    return "\n".join(sections)


def render(model: dict[str, Any], fmt: str) -> str:
    """Render ``model`` in ``fmt`` (one of ``FORMATS``), without a final newline.

    Args:
        model: A ``comment.v1`` document.
        fmt: ``compact`` or ``table``.

    Returns:
        The comment markdown.

    Raises:
        ValueError: When ``fmt`` is not a format this module lays out.
    """
    if fmt == "compact":
        return _compact(model)
    if fmt == "table":
        return _table_format(model)
    raise ValueError("unknown comment format")


def write(model: dict[str, Any], fmt: str, out: str) -> None:
    """Write ``model`` in ``fmt`` to the file ``out``, or to stdout when empty.

    Args:
        model: A ``comment.v1`` document.
        fmt: ``compact`` or ``table``.
        out: Path of the comment file; empty for stdout.
    """
    body = render(model, fmt) + "\n"
    if out:
        Path(out).write_text(body, encoding="utf-8")
    else:
        sys.stdout.write(body)
        sys.stdout.flush()
