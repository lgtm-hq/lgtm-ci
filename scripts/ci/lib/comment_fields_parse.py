#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Parse caller ``comment-fields`` input and write its job log lines (#1677).

One ``Label: value`` per line; the rules, limits and stable messages are in
``docs/comment-fields.md``. Nothing here raises on bad input: a bad line
becomes a :class:`Note`, an unreadable input a whole-input problem.
``comment_fields.py`` renders the result into the comment.

Standard library only and Python 3.10 compatible: the poster runs it on the
caller's runner (3.10 on ``ubuntu-22.04``).
"""

from __future__ import annotations

import re
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Union

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:  # python3 -I leaves scripts/ci/lib off sys.path
    sys.path.insert(0, _LIB_DIR)

import comment_sanitize  # noqa: E402  # pylint: disable=wrong-import-position

#: Largest input read, in bytes of UTF-8.
MAX_INPUT_BYTES = 8192
#: Fields shown; later valid lines get a note.
MAX_FIELDS = 20
#: Longest label, in characters after trimming.
MAX_LABEL_CHARS = 64
#: Longest value, in characters after trimming.
MAX_VALUE_CHARS = 512
#: Notes shown in the comment; the rest are counted in one closing note.
MAX_NOTES = 10
#: Problems listed in the job log; the rest are counted in one line.
MAX_LOG_PROBLEMS = 50
#: Name shown in notes and log lines.
NAME = "comment-fields"

_EXAMPLE = "Environment: staging"
_LINK_EXAMPLE = "Environment URL: https://staging.example.com"
#: Line problems: code to (message, example of a correct line). Messages are
#: stable; tests and the docs quote them.
REASONS: dict[str, tuple[str, str]] = {
    "invisible": ("the line contains a control or invisible character", _EXAMPLE),
    "no-colon": ("no colon found", _EXAMPLE),
    "empty-label": ("nothing before the colon", _EXAMPLE),
    "label-too-long": (
        f"the label is longer than {MAX_LABEL_CHARS} characters",
        _EXAMPLE,
    ),
    "empty-value": ("nothing after the colon", _EXAMPLE),
    "value-too-long": (
        f"the value is longer than {MAX_VALUE_CHARS} characters",
        _EXAMPLE,
    ),
    "no-label": ("a link needs a label before it", _LINK_EXAMPLE),
    "not-https": ("links must start with https://", _LINK_EXAMPLE),
    "unsafe-link": (
        "a link must be a whole https:// address with a plain host name",
        _LINK_EXAMPLE,
    ),
    "duplicate": ("this label is already used on line {first}", "Region: eu-west-1"),
    "too-many": (f"more than {MAX_FIELDS} fields; this one is not shown", _EXAMPLE),
}
#: Whole-input problems: code to message.
INPUT_REASONS: dict[str, str] = {
    "too-large": f"the input is larger than {MAX_INPUT_BYTES} bytes",
    "not-utf8": "the input is not valid UTF-8 text",
}
_FORMAT_HELP = (
    f'{NAME}: write one field per line as "Label: value". The label is the text '
    "before the first colon, the value is the rest of the line; a value that is "
    "an https:// address is shown as a link. Blank lines and lines starting "
    "with # are skipped. Rules: docs/comment-fields.md"
)

_LINK_SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://")
_BARE_SCHEME = re.compile(
    r"(?i)(?:javascript|vbscript):|data:[a-z-]+/|file:/|mailto:\S",
)
_SCHEME_WORD = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*")
_FLAGGED_CATEGORIES = frozenset({"Cc", "Cf", "Cs", "Co", "Zl", "Zp"})
_INVISIBLE_LETTERS = frozenset("\u115f\u1160\u3164\uffa0")


@dataclass(frozen=True)
class Field:
    """One valid field, as the caller wrote it (trimmed, not yet sanitised)."""

    label: str
    value: str
    link: bool


@dataclass(frozen=True)
class Note:
    """A line that is not shown: its number and the reason, written by lgtm-ci."""

    line: int
    code: str
    reason: str


Item = Union[Field, Note]


@dataclass
class Parsed:
    """The parsed input: fields and notes in input order, or a whole-input problem."""

    items: list[Item] = field(default_factory=list)
    problem: str = ""

    @property
    def fields(self) -> list[Field]:
        """The valid fields, in order."""
        return [item for item in self.items if isinstance(item, Field)]

    @property
    def notes(self) -> list[Note]:
        """The notes, in order."""
        return [item for item in self.items if isinstance(item, Note)]

    @property
    def empty(self) -> bool:
        """Tell whether there is nothing to show (no field, note or problem)."""
        return not self.items and not self.problem


def _hidden_char(char: str) -> bool:
    """Tell whether ``char`` is a control, invisible or line-separator character."""
    if char == "\t" or char in _INVISIBLE_LETTERS:
        return char != "\t"
    return unicodedata.category(char) in _FLAGGED_CATEGORIES


def _flagged(line: str) -> bool:
    """Tell whether a line holds a control, invisible or line-separator character."""
    return any(_hidden_char(char) for char in line)


def _line_problem(label: str, value: str) -> str:
    """Return the problem code of a split line, or ``""`` when it is valid."""
    problem = ""
    if value.startswith("//") and _SCHEME_WORD.fullmatch(label):
        problem = "no-label"
    elif not label:
        problem = "empty-label"
    elif len(label) > MAX_LABEL_CHARS:
        problem = "label-too-long"
    elif not value:
        problem = "empty-value"
    elif len(value) > MAX_VALUE_CHARS:
        problem = "value-too-long"
    elif _LINK_SCHEME.match(value) or _BARE_SCHEME.match(value):
        if not value.lower().startswith("https://"):
            problem = "not-https"
        elif comment_sanitize.url(value) is None:
            problem = "unsafe-link"
    return problem


def _note(number: int, code: str, **values: int) -> Note:
    """Build the note for line ``number``."""
    return Note(number, code, REASONS[code][0].format(**values))


def parse(raw: bytes | str) -> Parsed:
    """Parse ``comment-fields`` input; never raises on bad input.

    Args:
        raw: The input as bytes (decoded as strict UTF-8) or text.

    Returns:
        The fields and notes in input order, or a whole-input problem.
    """
    if isinstance(raw, str):
        raw = raw.encode("utf-8", errors="surrogateescape")
    data: bytes = raw
    if len(data) > MAX_INPUT_BYTES:
        return Parsed(problem="too-large")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return Parsed(problem="not-utf8")
    parsed = Parsed()
    first_line: dict[str, int] = {}
    shown = 0
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    for number, line in enumerate(lines, start=1):
        stripped = line.strip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        if _flagged(stripped):
            parsed.items.append(_note(number, "invisible"))
            continue
        if ":" not in stripped:
            parsed.items.append(_note(number, "no-colon"))
            continue
        label, _, value = stripped.partition(":")
        label, value = label.strip(" \t"), value.strip(" \t")
        problem = _line_problem(label, value)
        key = label.casefold()
        if problem:
            parsed.items.append(_note(number, problem))
        elif key in first_line:
            parsed.items.append(_note(number, "duplicate", first=first_line[key]))
        elif shown >= MAX_FIELDS:
            parsed.items.append(_note(number, "too-many"))
        else:
            first_line[key] = number
            shown += 1
            is_link = value.lower().startswith("https://")
            parsed.items.append(Field(label, value, is_link))
    return parsed


def log_lines(parsed: Parsed) -> list[str]:
    """Return the job log lines for ``parsed``, the ``::warning`` last.

    No line carries the input itself: only line numbers and lgtm-ci's text,
    so the input can never start a workflow command.
    """
    if parsed.empty:
        return []
    if parsed.problem:
        reason = INPUT_REASONS[parsed.problem]
        warning = f"::warning title={NAME}::{NAME} could not be read"
        return [
            f"{NAME}: the input could not be read: {reason}; no field is shown.",
            _FORMAT_HELP,
            f"{warning}: {reason}; no field is shown",
        ]
    notes = parsed.notes
    shown = len(parsed.fields)
    lines = [f"{NAME}: {shown} {'field' if shown == 1 else 'fields'} shown."]
    if not notes:
        return lines
    for note in notes[:MAX_LOG_PROBLEMS]:
        example = REASONS[note.code][1]
        correct = f'A correct line looks like "{example}".'
        lines.append(f"{NAME}: line {note.line}: {note.reason}. {correct}")
    if len(notes) > MAX_LOG_PROBLEMS:
        lines.append(f"{NAME}: {len(notes) - MAX_LOG_PROBLEMS} more lines not listed.")
    lines.append(_FORMAT_HELP)
    numbers = ", ".join(str(note.line) for note in notes[:MAX_NOTES])
    if len(notes) > MAX_NOTES:
        numbers += ", …"
    which = "line" if len(notes) == 1 else "lines"
    lines.append(
        f"::warning title={NAME}::{len(notes)} {NAME} {which} not shown ({which} "
        f"{numbers}); the job log lists each reason",
    )
    return lines
