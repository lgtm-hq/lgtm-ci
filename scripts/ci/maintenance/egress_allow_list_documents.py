# SPDX-License-Identifier: MIT
"""Find the hosts that documents tell users to allow-list (#1548, #1582).

Used by ``check-egress-dns.py``. A unit is a whole ``.yml``/``.yaml`` file
under ``docs/`` or ``examples/``, or one fenced code block of a ``.md`` file
there; a unit is read only if it contains ``allowed-endpoints`` anywhere.
From such a unit every ``host:port`` token is collected, wherever it stands
and whatever the shape around it (``${{ ... }}`` expressions removed), so
nothing in a document's shape can hide such a token or fail the run; only a
file that cannot be read or decoded is an error.

What is not seen: an entry that is not a ``host:port`` token. The agent takes
a host without a port (it defaults to 443) and ignores a port it cannot parse,
so ``github.com`` or ``my_host.io:443`` in a document would reach the agent
but is not collected here. Collecting bare dotted names would sweep in file
names and expression paths, so examples must always write ``host:port``.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

# What makes a unit relevant.
MARKER = "allowed-endpoints"
# One allow-list entry, as the checker validates it.
ENDPOINT = re.compile(r"^(?P<host>[a-z0-9.*-]+):(?P<port>\d{1,5})$")
_LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
# A DNS host name with at least one dot; the last label starts with a letter.
HOSTNAME = re.compile(rf"^{_LABEL}(?:\.{_LABEL})*\.[a-z][a-z0-9-]*[a-z0-9]$")
# A host:port token anywhere in a line. The host may hold ``*`` (a wildcard).
# Not after a letter, digit, ``.``, ``-``, ``_`` or ``*``; not before a
# letter, digit, ``_``, or a ``.`` followed by a digit (a version number).
TOKEN = re.compile(
    r"(?<![a-z0-9._*-])"
    r"(?P<host>[a-z0-9*][a-z0-9*-]*(?:\.[a-z0-9*-]+)*\.[a-z][a-z0-9*-]*)"
    r":(?P<port>\d{1,5})"
    r"(?![a-z0-9_]|\.\d)",
    # ASCII: under IGNORECASE alone, U+017F and U+0131 would match s and i,
    # and the checker would then reject the token and fail the run.
    re.IGNORECASE | re.ASCII,
)
# One piece of a Markdown container prefix: spaces, a blockquote marker with
# its optional space, or a list marker followed by a space or the line end.
CONTAINER = re.compile(r" +|> ?|(?:[-+*]|\d{1,9}[.)])(?= |$)")
# A blockquote marker on a block's line, after any indentation.
QUOTE_MARKER = re.compile(r" *> ?")
FENCE_OPENING = re.compile(r"(?P<marks>`{3,}|~{3,})(?P<info>.*)$")
FENCE_CLOSING = re.compile(r"^(?P<lead> *)(?P<marks>`{3,}|~{3,})\s*$")

Numbered = list[tuple[int, str]]


class DnsCheckError(Exception):
    """Raised when the check cannot reach a trustworthy verdict; it fails closed."""


@dataclass(frozen=True)
class _Fence:
    """An open fenced code block.

    Attributes:
        marks: The opening fence marks, such as three backticks.
        quotes: How many blockquote markers precede it.
        column: The fence's column after its last blockquote marker.
    """

    marks: str
    quotes: int
    column: int


def _strip_quotes(line: str, limit: int) -> tuple[int, str]:
    """Remove up to ``limit`` blockquote markers from the start of a line.

    Args:
        line: The line, tabs expanded.
        limit: The most markers to remove.

    Returns:
        The number of markers removed and the rest of the line.
    """
    count = 0
    while count < limit:
        match = QUOTE_MARKER.match(line)
        if match is None:
            break
        line = line[match.end() :]
        count += 1
    return count, line


def _fence_opening(line: str) -> _Fence | None:
    """Return the fence a Markdown line opens, or None.

    The container prefix is consumed piece by piece, in any order and
    nesting: spaces, ``>`` markers and list markers (``-``, ``*``, ``+``,
    ``1.``, ``1)``). Each piece is at least one character and no pattern
    backtracks across pieces, so the scan is linear in the line's length.

    Args:
        line: The line, tabs expanded.

    Returns:
        The fence, with its container prefix, or None for any other line.
    """
    position, quotes, after = 0, 0, 0
    while (piece := CONTAINER.match(line, position)) is not None:
        if piece.group()[0] == ">":
            quotes += 1
            after = piece.end()
        position = piece.end()
    match = FENCE_OPENING.match(line, position)
    if match is None:
        return None
    marks = match.group("marks")
    # A backtick fence's info string cannot hold a backtick (CommonMark).
    if marks[0] == "`" and "`" in match.group("info"):
        return None
    return _Fence(marks=marks, quotes=quotes, column=position - after)


def _closes_fence(text: str, fence: _Fence) -> bool:
    """Tell whether a block line (blockquote markers removed) closes the fence.

    The closing fence uses the opening's character, at least as many times,
    with nothing after it, indented at most three columns past the fence.
    """
    match = FENCE_CLOSING.match(text)
    if match is None or len(match.group("lead")) > fence.column + 3:
        return False
    marks = match.group("marks")
    return marks[0] == fence.marks[0] and len(marks) >= len(fence.marks)


def _fenced_blocks(lines: list[str]) -> Iterator[Numbered]:
    """Yield the lines of each fenced code block of a Markdown document.

    Fences are found inside list items and blockquotes too. A line without
    the blockquote markers the fence opened under ends the block, as in
    CommonMark; a block that never closes ends with the document. Tabs are
    expanded to stops of four columns. Lines outside blocks are not read.

    Args:
        lines: The document's lines.

    Yields:
        ``(line number, text)`` pairs of each block, without its fences.
    """
    fence: _Fence | None = None
    block: Numbered = []
    for number, raw in enumerate(lines, start=1):
        line = raw.expandtabs(4)
        if fence is not None:
            quotes, text = _strip_quotes(line, limit=fence.quotes)
            inside = quotes == fence.quotes
            if inside and not _closes_fence(text, fence):
                block.append((number, text))
                continue
            yield block
            fence, block = None, []
            if inside:
                continue
            # The blockquote ended, and the block with it: read the line anew.
        fence = _fence_opening(line)
    if fence is not None:
        yield block


def _without_expressions(text: str) -> str:
    """Replace each ``${{ ... }}`` with a space, keeping its line breaks.

    A forward scan with plain searches: an opener with no closer after it
    ends the scan, so a run of unclosed openers costs linear time.

    Args:
        text: A unit's text.

    Returns:
        The text with the same number of lines and no expression.
    """
    parts: list[str] = []
    cursor = 0
    while True:
        start = text.find("${{", cursor)
        end = text.find("}}", start + 3) if start >= 0 else -1
        if end < 0:
            parts.append(text[cursor:])
            return "".join(parts)
        parts.append(text[cursor:start])
        parts.append(" " + "\n" * text.count("\n", start, end))
        cursor = end + 2


def _tokens(unit: Numbered) -> Iterator[tuple[int, str]]:
    """Yield every ``host:port`` token of a relevant unit.

    Args:
        unit: ``(line number, text)`` pairs of a YAML file or a fenced block.

    Yields:
        ``(line number, token)`` pairs, the host lower-cased. Nothing for a
        unit that does not mention ``allowed-endpoints``.
    """
    joined = "\n".join(text for _, text in unit)
    if MARKER not in joined:
        return
    joined = _without_expressions(joined)
    for (number, _), text in zip(unit, joined.split("\n"), strict=True):
        for match in TOKEN.finditer(text):
            host = match.group("host").lower()
            if not 0 < int(match.group("port")) < 65536:
                continue
            if "*" in host or HOSTNAME.match(host):
                yield number, f"{host}:{match.group('port')}"


def allow_list_entries(lines: list[str], markdown: bool) -> Iterator[tuple[int, str]]:
    """Yield the ``host:port`` tokens of a document's relevant units.

    Args:
        lines: The document's lines; a leading byte order mark is ignored.
        markdown: True to read each fenced code block as a unit, False to
            read the whole document as one.

    Yields:
        ``(line number, token)`` pairs, 1-based.
    """
    if lines and lines[0].startswith("﻿"):
        lines = [lines[0][1:], *lines[1:]]
    if not markdown:
        yield from _tokens(list(enumerate(lines, start=1)))
        return
    for block in _fenced_blocks(lines):
        yield from _tokens(block)


def document_endpoints(root: Path = ROOT) -> list[tuple[str, str]]:
    """Read the allow-list entries in ``docs/`` and ``examples/``.

    Args:
        root: Repository root.

    Returns:
        ``(path:line, endpoint)`` pairs, sorted by path.

    Raises:
        DnsCheckError: When a document cannot be read or decoded.
    """
    paths = sorted(
        path
        for folder in ("docs", "examples")
        for path in (root / folder).rglob("*")
        if path.suffix in {".md", ".yml", ".yaml"} and path.is_file()
    )
    pairs: list[tuple[str, str]] = []
    for path in paths:
        try:
            lines = path.read_text("utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as error:
            raise DnsCheckError(f"could not read {path}: {error}") from error
        relative = path.relative_to(root).as_posix()
        for number, token in allow_list_entries(lines, path.suffix == ".md"):
            pairs.append((f"{relative}:{number}", token))
    return pairs
