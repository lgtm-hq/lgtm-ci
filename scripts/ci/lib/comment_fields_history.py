#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""History stamp of caller ``comment-fields`` (#1677).

With ``comment-history`` on, the latest stamp of a pull request comment
carries the run's fields as ``fields=<base64 of JSON>``. When that result is
archived, :func:`history_text` renders the run's entry line from it. The line
sits inside a raw-HTML ``<summary>``, so it uses the sanitiser's ``html``
mode: no markdown escapes, nothing live. The stamp is decoded defensively and
sanitised again; it is never trusted.

Standard library only and Python 3.10 compatible.
"""

from __future__ import annotations

import base64
import binascii
import json
import sys
from pathlib import Path

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:  # python3 -I leaves scripts/ci/lib off sys.path
    sys.path.insert(0, _LIB_DIR)

# pylint: disable=wrong-import-position
import comment_sanitize  # noqa: E402
from comment_fields_parse import MAX_FIELDS, Parsed  # noqa: E402

# pylint: enable=wrong-import-position

#: Label and value length kept for the history line of an archived run.
HISTORY_LABEL_CHARS = 32
HISTORY_VALUE_CHARS = 60
#: Largest stamp written, in base64 characters; later fields are counted.
MAX_STAMP_CHARS = 1024
#: Largest stamp read back; anything longer is ignored.
MAX_STAMP_READ = 4096


def _count(value: int) -> str:
    """Render a whole number the renderer computed."""
    return str(int(value))


def _encode(data: dict[str, object]) -> str:
    """Encode ``data`` as base64 of compact ASCII JSON."""
    encoded = json.dumps(data, ensure_ascii=True, separators=(",", ":"))
    return base64.b64encode(encoded.encode("ascii")).decode("ascii")


def history_stamp(parsed: Parsed) -> str:
    """Encode what an archived run's history line shows, as base64 of JSON.

    Labels and values are cut to the history lengths; a link keeps only its
    host (and a port other than 443). The stamp is at most
    ``MAX_STAMP_CHARS``: fields that do not fit are counted in ``x``. ``""``
    when there is nothing to show.
    """
    if parsed.empty:
        return ""
    kept: list[list[str]] = []
    for item in parsed.fields:
        value = item.value
        if item.link:
            value = comment_sanitize.display_host(item.value) or ""
        kept.append(
            [
                comment_sanitize.cap(item.label, HISTORY_LABEL_CHARS),
                comment_sanitize.cap(value, HISTORY_VALUE_CHARS),
            ],
        )
    data: dict[str, object] = {
        "v": 1,
        "f": kept,
        "n": len(parsed.notes),
        "u": int(bool(parsed.problem)),
    }
    stamp = _encode(data)
    while len(stamp) > MAX_STAMP_CHARS and kept:
        kept.pop()
        data["x"] = len(parsed.fields) - len(kept)
        stamp = _encode(data)
    return stamp


def _decode_stamp(stamp: str) -> dict[str, object] | None:
    """Decode a history stamp; ``None`` when it is not one this module wrote."""
    if len(stamp) > MAX_STAMP_READ:
        return None
    try:
        decoded = base64.b64decode(stamp.strip(), validate=True)
        data = json.loads(decoded.decode("utf-8"))
    except (ValueError, binascii.Error, UnicodeDecodeError, RecursionError):
        return None
    if not isinstance(data, dict) or data.get("v") != 1:
        return None
    pairs = data.get("f")
    valid = (
        isinstance(pairs, list)
        and all(
            isinstance(pair, list)
            and len(pair) == 2
            and all(isinstance(part, str) for part in pair)
            for pair in pairs
        )
        and isinstance(data.get("n"), int)
        and isinstance(data.get("u"), int)
        and isinstance(data.get("x", 0), int)
    )
    return data if valid else None


def history_text(stamp: str) -> str:
    """Render the history line of an archived run from its stamp, for raw HTML.

    The stamp is re-sanitised here (``html`` mode): the line never trusts
    what it decodes.
    """
    data = _decode_stamp(stamp)
    if data is None:
        return ""
    sections: list[str] = []
    pairs: list[list[str]] = data["f"]  # type: ignore[assignment]
    for pair in pairs[:MAX_FIELDS]:
        label = comment_sanitize.html(pair[0], max_chars=HISTORY_LABEL_CHARS)
        value = comment_sanitize.html(pair[1], max_chars=HISTORY_VALUE_CHARS)
        sections.append(f"{label}: {value}")
    extra = data.get("x", 0)
    if isinstance(extra, int) and extra > 0:
        sections.append(f"+{_count(min(extra, 99))} more")
    notes = data["n"]
    if data["u"]:
        sections.append("⚠️ fields unreadable")
    elif isinstance(notes, int) and notes > 0:
        count = _count(min(notes, 9999))
        word = "line" if notes == 1 else "lines"
        sections.append(f"⚠️ {count} field {word} not shown")
    return " · ".join(sections)
