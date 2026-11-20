#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Caller-supplied labelled values on every pull request comment (#1677).

A caller passes ``comment-fields``, one ``Label: value`` per line.
``comment_fields_parse.py`` parses that untrusted text and writes the job log
lines; this module renders the fields in one of three styles, keeps the
history stamp and runs the command line. A bad line never fails anything: it
becomes a note, written by lgtm-ci, in the place of the field. The rules,
limits and messages are in ``docs/comment-fields.md``.

Styles (#1678 picks between them; the poster uses ``block``):

- ``block``: a quoted block, one ``> **Label:** value`` line per field;
- ``compact``: one line, fields joined by `` · ``;
- ``table``: a two-row table, labels in the header row.

Every label and value goes through ``comment_sanitize``: ``text`` (``cell``
in a table) for labels and plain values, ``link`` for an HTTPS value, whose
visible text is its host.

Command line (the input never travels on argv)::

    python3 -I -S comment_fields.py render [--env NAME] [--style STYLE]
        [--out FILE] [--stamp FILE]
    python3 -I -S comment_fields.py history [--env NAME]

``render`` reads the input from ``NAME`` (or stdin), the run URL for notes from
``COMMENT_FIELDS_RUN_URL``, writes the block to ``--out`` (stdout when absent)
and the history stamp to ``--stamp``, and prints the log lines on stdout (on
stderr when the block goes to stdout). ``history`` reads a stamp and prints
the compact line shown on an archived run. Exit status 2 is a usage error;
anything about the input itself exits 0.

Standard library only and Python 3.10 compatible: the poster runs it on the
caller's runner (3.10 on ``ubuntu-22.04``).
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import sys
from pathlib import Path

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:  # python3 -I leaves scripts/ci/lib off sys.path
    sys.path.insert(0, _LIB_DIR)

# pylint: disable=wrong-import-position
import comment_sanitize  # noqa: E402
from comment_fields_parse import (  # noqa: E402
    INPUT_REASONS,
    MAX_FIELDS,
    MAX_NOTES,
    REASONS,
    Field,
    Item,
    Note,
    Parsed,
    log_lines,
    parse,
)

# pylint: enable=wrong-import-position

__all__ = [
    "REASONS",
    "INPUT_REASONS",
    "STYLES",
    "Field",
    "Note",
    "Parsed",
    "history_stamp",
    "history_text",
    "log_lines",
    "main",
    "parse",
    "render",
]

#: Render styles.
STYLES = ("block", "compact", "table")
#: Environment variable holding the run URL that notes link to.
RUN_URL_ENV = "COMMENT_FIELDS_RUN_URL"
#: Opening of every note in the comment.
NOTE = "⚠️ `comment-fields`"
#: Visible text of the run link in a note.
RUN_LINK_TEXT = "job log"
#: Label and value length kept for the history line of an archived run.
HISTORY_LABEL_CHARS = 32
HISTORY_VALUE_CHARS = 60


def _count(value: int) -> str:
    """Render a whole number the renderer computed."""
    return str(int(value))


def _visible(parsed: Parsed) -> tuple[list[Item], int]:
    """Return the items shown in the comment and how many notes were held back."""
    shown: list[Item] = []
    held = 0
    notes = 0
    for item in parsed.items:
        if isinstance(item, Note):
            notes += 1
            if notes > MAX_NOTES:
                held += 1
                continue
        shown.append(item)
    return shown, held


def render_block(parsed: Parsed, run_url: str = "") -> str:
    """Render the fields as a quoted block, one line per field or note.

    Args:
        parsed: The parsed input.
        run_url: URL of the job run that notes link to.

    Returns:
        The block without a trailing newline, or ``""`` when there is nothing.
    """
    sections: list[str] = []
    suffix = (
        f" ({comment_sanitize.labelled_link(run_url, RUN_LINK_TEXT)})"
        if comment_sanitize.url(run_url)
        else ""
    )
    if parsed.problem:
        reason = comment_sanitize.text(INPUT_REASONS[parsed.problem])
        sections.append(f"> {NOTE} could not be read: {reason}{suffix}")
        return "\n".join(sections)
    shown, held = _visible(parsed)
    for item in shown:
        if isinstance(item, Field):
            label = comment_sanitize.text(item.label)
            value = (
                comment_sanitize.link(item.value)
                if item.link
                else comment_sanitize.text(item.value)
            )
            sections.append(f"> **{label}:** {value}")
        else:
            number = _count(item.line)
            reason = comment_sanitize.text(item.reason)
            sections.append(f"> {NOTE} line {number}: {reason}{suffix}")
    if held:
        more = _count(held)
        sections.append(f"> {NOTE}: {more} more lines not shown{suffix}")
    return "\n".join(sections)


def render_compact(parsed: Parsed, run_url: str = "") -> str:
    """Render the fields on one line, joined by `` · ``.

    Args:
        parsed: The parsed input.
        run_url: URL of the job run that notes link to.

    Returns:
        The line, or ``""`` when there is nothing.
    """
    sections: list[str] = []
    suffix = (
        f" ({comment_sanitize.labelled_link(run_url, RUN_LINK_TEXT)})"
        if comment_sanitize.url(run_url)
        else ""
    )
    if parsed.problem:
        reason = comment_sanitize.text(INPUT_REASONS[parsed.problem])
        sections.append(f"{NOTE} could not be read: {reason}{suffix}")
        return " · ".join(sections)
    shown, held = _visible(parsed)
    for item in shown:
        if isinstance(item, Field):
            label = comment_sanitize.text(item.label)
            value = (
                comment_sanitize.link(item.value)
                if item.link
                else comment_sanitize.text(item.value)
            )
            sections.append(f"**{label}:** {value}")
        else:
            number = _count(item.line)
            reason = comment_sanitize.text(item.reason)
            sections.append(f"{NOTE} line {number}: {reason}{suffix}")
    if held:
        more = _count(held)
        sections.append(f"{NOTE}: {more} more lines not shown{suffix}")
    return " · ".join(sections)


def render_table(parsed: Parsed, run_url: str = "") -> str:
    """Render the fields as a table: labels in the header row, values below.

    Args:
        parsed: The parsed input.
        run_url: URL of the job run that notes link to.

    Returns:
        The table without a trailing newline, or ``""`` when there is nothing.
    """
    sections: list[tuple[str, str]] = []
    suffix = (
        f" ({comment_sanitize.labelled_link(run_url, RUN_LINK_TEXT)})"
        if comment_sanitize.url(run_url)
        else ""
    )
    if parsed.problem:
        reason = comment_sanitize.cell(INPUT_REASONS[parsed.problem])
        sections.append((NOTE, f"could not be read: {reason}{suffix}"))
    shown, held = ([], 0) if parsed.problem else _visible(parsed)
    for item in shown:
        if isinstance(item, Field):
            label = comment_sanitize.cell(item.label)
            value = (
                comment_sanitize.link(item.value)
                if item.link
                else comment_sanitize.cell(item.value)
            )
            sections.append((label, value))
        else:
            number = _count(item.line)
            reason = comment_sanitize.cell(item.reason)
            sections.append((f"{NOTE} line {number}", f"{reason}{suffix}"))
    if held:
        more = _count(held)
        sections.append((NOTE, f"{more} more lines not shown{suffix}"))
    if not sections:
        return ""
    header = " | ".join(head for head, _ in sections)
    rule = "|".join("---" for _ in sections)
    row = " | ".join(cell for _, cell in sections)
    return f"| {header} |\n|{rule}|\n| {row} |"


RENDERERS = {"block": render_block, "compact": render_compact, "table": render_table}


def render(parsed: Parsed, style: str = "block", run_url: str = "") -> str:
    """Render ``parsed`` in ``style``; ``""`` when there is nothing to show."""
    if parsed.empty:
        return ""
    return RENDERERS[style](parsed, run_url)


def history_stamp(parsed: Parsed) -> str:
    """Encode what an archived run's history line shows, as base64 of JSON.

    Labels and values are cut to the history lengths; a link keeps only its
    host. ``""`` when there is nothing to show.
    """
    if parsed.empty:
        return ""
    fields_kept = []
    for item in parsed.fields:
        value = (comment_sanitize.host(item.value) or "") if item.link else item.value
        fields_kept.append(
            [
                comment_sanitize.cap(item.label, HISTORY_LABEL_CHARS),
                comment_sanitize.cap(value, HISTORY_VALUE_CHARS),
            ],
        )
    data = {
        "v": 1,
        "f": fields_kept,
        "n": len(parsed.notes),
        "u": int(bool(parsed.problem)),
    }
    encoded = json.dumps(data, ensure_ascii=True, separators=(",", ":"))
    return base64.b64encode(encoded.encode("ascii")).decode("ascii")


def _decode_stamp(stamp: str) -> dict[str, object] | None:
    """Decode a history stamp; ``None`` when it is not one this module wrote."""
    try:
        decoded = base64.b64decode(stamp.strip(), validate=True)
        data = json.loads(decoded.decode("utf-8"))
    except (ValueError, binascii.Error, UnicodeDecodeError):
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
    )
    return data if valid else None


def history_text(stamp: str) -> str:
    """Render the compact history line of an archived run from its stamp.

    The stamp is re-sanitised here: the line never trusts what it decodes.
    """
    data = _decode_stamp(stamp)
    if data is None:
        return ""
    sections: list[str] = []
    pairs: list[list[str]] = data["f"]  # type: ignore[assignment]
    for pair in pairs[:MAX_FIELDS]:
        label = comment_sanitize.text(pair[0], max_chars=HISTORY_LABEL_CHARS)
        value = comment_sanitize.text(pair[1], max_chars=HISTORY_VALUE_CHARS)
        sections.append(f"{label}: {value}")
    notes = data["n"]
    if data["u"]:
        sections.append("⚠️ fields unreadable")
    elif isinstance(notes, int) and notes > 0:
        count = _count(min(notes, 9999))
        word = "line" if notes == 1 else "lines"
        sections.append(f"⚠️ {count} field {word} not shown")
    return " · ".join(sections)


_USAGE = (
    "usage: comment_fields.py render [--env NAME] [--style STYLE] [--out FILE] "
    "[--stamp FILE]\n       comment_fields.py history [--env NAME]\n"
)


def _parse_args(argv: list[str]) -> dict[str, str] | None:
    """Parse the command line; ``None`` on a usage error."""
    if not argv or argv[0] not in {"render", "history"}:
        return None
    options = {"command": argv[0], "--style": "block"}
    allowed = {"--env"}
    if argv[0] == "render":
        allowed |= {"--style", "--out", "--stamp"}
    rest = argv[1:]
    seen: set[str] = set()
    while rest:
        flag = rest.pop(0)
        if flag not in allowed or flag in seen or not rest:
            return None
        seen.add(flag)
        options[flag] = rest.pop(0)
    if options["--style"] not in STYLES:
        return None
    return options


def _read_input(name: str | None) -> bytes:
    """Read the raw input from the environment variable ``name`` or stdin."""
    if name is None:
        return sys.stdin.buffer.read()
    return os.environb.get(name.encode("utf-8"), b"")


def main(argv: list[str]) -> int:
    """Run the command line; see the module docstring.

    Args:
        argv: Arguments after the program name.

    Returns:
        The exit status.
    """
    options = _parse_args(argv)
    if options is None:
        sys.stderr.write(_USAGE)
        return 2
    raw = _read_input(options.get("--env"))
    if options["command"] == "history":
        line = history_text(raw.decode("ascii", errors="replace"))
        sys.stdout.buffer.write(line.encode("utf-8"))
        return 0
    parsed = parse(raw)
    block = render(parsed, options["--style"], os.environ.get(RUN_URL_ENV, ""))
    out = options.get("--out")
    if out is None:
        sys.stdout.buffer.write(block.encode("utf-8"))
        log = sys.stderr.buffer
    else:
        Path(out).write_bytes(block.encode("utf-8"))
        log = sys.stdout.buffer
    if "--stamp" in options:
        Path(options["--stamp"]).write_text(history_stamp(parsed), encoding="ascii")
    log.write("".join(line + "\n" for line in log_lines(parsed)).encode("utf-8"))
    log.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
