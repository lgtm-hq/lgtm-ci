#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Caller-supplied labelled values on every pull request comment (#1677).

A caller passes ``comment-fields``, one ``Label: value`` per line.
``comment_fields_parse.py`` parses that untrusted text and writes the job log
lines; this module renders the fields in one of three styles, within a size
budget, and runs the command line; ``comment_fields_history.py`` keeps the
history stamp. A bad line never fails anything: it
becomes a note, written by lgtm-ci, in the place of the field. The rules,
limits and messages are in ``docs/comment-fields.md``.

Styles (#1678 picks between them; the poster uses ``block``):

- ``block``: a quoted block, one ``> **Label:** value`` line per field;
- ``compact``: one line, fields joined by `` · ``;
- ``table``: a two-row table, labels in the header row.

Every label and value goes through ``comment_sanitize``: ``cell`` (the same
as ``text``) for labels and plain values, ``link`` for an HTTPS value, whose
visible text is its host, and ``code`` for a link to a GitHub host, which is
shown as text so it creates no cross-reference.

Command line (the input never travels on argv)::

    python3 -I -S comment_fields.py render [--env NAME] [--style STYLE]
        [--out FILE] [--stamp FILE]
    python3 -I -S comment_fields.py history [--env NAME]

``render`` reads the input from ``NAME`` (or stdin), the run URL for notes from
``COMMENT_FIELDS_RUN_URL``, writes the block to ``--out`` (stdout when absent)
and the history stamp to ``--stamp``, and prints the log lines on stdout (on
stderr when the block goes to stdout). ``history`` reads a stamp and prints
the compact line shown on an archived run. Exit status 2 is a usage error;
anything about the input itself, or an internal error, exits 0.

Standard library only and Python 3.10 compatible: the poster runs it on the
caller's runner (3.10 on ``ubuntu-22.04``).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:  # python3 -I leaves scripts/ci/lib off sys.path
    sys.path.insert(0, _LIB_DIR)

# pylint: disable=wrong-import-position
import comment_sanitize  # noqa: E402
from comment_fields_history import history_stamp, history_text  # noqa: E402
from comment_fields_parse import (  # noqa: E402
    INPUT_REASONS,
    MAX_NOTES,
    NAME,
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
    "INPUT_REASONS",
    "REASONS",
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
#: Most characters the rendered block may take, in every style (#1677). The
#: input cap is on raw bytes; escaping can make a value five times longer, so
#: the rendered size is capped as well, to keep the comment under GitHub's
#: 65,536 characters.
BLOCK_BUDGET = 4000
#: Characters counted per part on top of its label and value: the widest
#: style's markup (table cell, separator row and pipes).
_PART_OVERHEAD = 16
#: Room kept for the closing notes.
_RESERVE = 400
#: Closing notes: notes over MAX_NOTES, and fields over the budget.
_HELD = "more lines not shown"
_CUT = "more fields not shown (size limit)"


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


def _parts(parsed: Parsed, run_url: str, table: bool) -> list[tuple[str, str, str]]:
    """Build the sanitised parts of the block, within ``BLOCK_BUDGET``.

    Each part is ``(separator, head, body)``: a field has an empty separator
    (``head`` is the label, ``body`` the value); a note joins its head and
    body with the separator, or puts them in two table columns.

    Args:
        parsed: The parsed input.
        run_url: URL of the job run that notes link to.
        table: Use the table-cell modes.

    Returns:
        The parts in input order, closing notes last.
    """
    sections: list[tuple[str, str, str]] = []
    suffix = (
        f" ({comment_sanitize.labelled_link(run_url, RUN_LINK_TEXT)})"
        if comment_sanitize.url(run_url)
        else ""
    )
    if parsed.problem:
        reason = comment_sanitize.cell(INPUT_REASONS[parsed.problem])
        sections.append((" ", NOTE, f"could not be read: {reason}{suffix}"))
        return sections
    shown, held = _visible(parsed)
    used = 0
    cut = 0
    for index, item in enumerate(shown):
        if isinstance(item, Field):
            part = (
                "",
                comment_sanitize.cell(item.label),
                (
                    comment_sanitize.link(item.value)
                    if item.link
                    else (
                        (
                            comment_sanitize.cell_code(item.value)
                            if table
                            else comment_sanitize.code(item.value)
                        )
                        if item.github
                        else comment_sanitize.cell(item.value)
                    )
                ),
            )
        else:
            part = (
                ": ",
                f"{NOTE} line {_count(item.line)}",
                f"{comment_sanitize.cell(item.reason)}{suffix}",
            )
        used += len(part[1]) + len(part[2]) + _PART_OVERHEAD
        if used > BLOCK_BUDGET - _RESERVE:
            cut = len(shown) - index
            break
        sections.append(part)
    if held:
        sections.append((": ", NOTE, f"{_count(held)} {_HELD}{suffix}"))
    if cut:
        sections.append((": ", NOTE, f"{_count(cut)} {_CUT}{suffix}"))
    return sections


def render_block(parsed: Parsed, run_url: str = "") -> str:
    """Render the fields as a quoted block, one line per field or note."""
    lines = [
        f"> **{head}:** {body}" if not sep else f"> {head}{sep}{body}"
        for sep, head, body in _parts(parsed, run_url, table=False)
    ]
    return "\n".join(lines)


def render_compact(parsed: Parsed, run_url: str = "") -> str:
    """Render the fields on one line, joined by `` · ``."""
    items = [
        f"**{head}:** {body}" if not sep else f"{head}{sep}{body}"
        for sep, head, body in _parts(parsed, run_url, table=False)
    ]
    return " · ".join(items)


def render_table(parsed: Parsed, run_url: str = "") -> str:
    """Render the fields as a table: labels in the header row, values below."""
    columns = _parts(parsed, run_url, table=True)
    if not columns:
        return ""
    header = " | ".join(head for _, head, _ in columns)
    rule = "|".join("---" for _ in columns)
    row = " | ".join(body for _, _, body in columns)
    return f"| {header} |\n|{rule}|\n| {row} |"


RENDERERS = {"block": render_block, "compact": render_compact, "table": render_table}


def render(parsed: Parsed, style: str = "block", run_url: str = "") -> str:
    """Render ``parsed`` in ``style``; ``""`` when there is nothing to show.

    Args:
        parsed: The parsed input.
        style: One of ``STYLES``.
        run_url: URL of the job run that notes link to.

    Returns:
        At most about ``BLOCK_BUDGET`` characters, without a trailing newline.
    """
    if parsed.empty:
        return ""
    return RENDERERS[style](parsed, run_url)


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


def _write(options: dict[str, str], parsed: Parsed, lines: list[str]) -> None:
    """Write the block, the stamp and the log lines for ``parsed``."""
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
    log.write("".join(line + "\n" for line in lines).encode("utf-8"))
    log.flush()


def _run(options: dict[str, str]) -> int:
    """Run one command; may raise on an internal error."""
    raw = _read_input(options.get("--env"))
    if options["command"] == "history":
        line = history_text(raw.decode("ascii", errors="replace"))
        sys.stdout.buffer.write(line.encode("utf-8"))
        return 0
    parsed = parse(raw)
    _write(options, parsed, log_lines(parsed))
    return 0


def main(argv: list[str]) -> int:
    """Run the command line; see the module docstring.

    An internal error never fails the step: ``render`` then writes the
    "could not be read: internal error" note, an unreadable stamp and one
    ``::warning``; ``history`` prints nothing.

    Args:
        argv: Arguments after the program name.

    Returns:
        The exit status: 2 for a usage error, else 0.
    """
    options = _parse_args(argv)
    if options is None:
        sys.stderr.write(_USAGE)
        return 2
    try:
        return _run(options)
    except Exception as error:  # pylint: disable=broad-exception-caught
        kind = type(error).__name__
        sys.stderr.write(f"{NAME}: internal error ({kind})\n")
        if options["command"] == "history":
            return 0
        reason = INPUT_REASONS["internal"]
        warning = f"::warning title={NAME}::{NAME} could not be read"
        lines = [
            f"{NAME}: the input could not be read: {reason}; no field is shown.",
            f"{warning}: {reason}; no field is shown",
        ]
        try:
            _write(options, Parsed(problem="internal"), lines)
        except Exception:  # pylint: disable=broad-exception-caught
            # The poster sees no block file and writes its own fixed note.
            sys.stderr.write("".join(line + "\n" for line in lines))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
