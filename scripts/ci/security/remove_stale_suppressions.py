#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Remove stale [[IgnoredVulns]] blocks from .osv-scanner.toml.

The file is edited line by line so every untouched line keeps its exact bytes
(comments, spacing, quoting, CRLF line endings, a missing final newline), but
``tomllib`` decides what the file means: the n-th ``[[IgnoredVulns]]`` header
line is matched to the n-th entry tomllib reads, and that entry's ``id``
decides whether the block goes. Only array-of-tables blocks of
``IgnoredVulns`` are ever removed; every other table (for example
``[[PackageOverrides]]``) stays where it is.

Block ownership:
    A block runs from its header to the next table header. Comment lines
    directly above a header, with no blank line in between, belong to that
    header's block: they are removed with it and kept with it. Every other
    line (a comment followed by a blank line, a trailing comment, blank
    separator lines) belongs to the block above it, or to the top of the file
    before the first block, which is never removed.

Blank lines:
    Removing a block removes the blank lines that follow it, so the
    separator before the removed block now separates its neighbours. When the
    removed blocks were at the end of the file, blank lines left at the end are
    trimmed to the number the original file ended with, and a file without a
    final newline keeps having none.

Fail closed:
    After editing, the result is parsed with tomllib and must equal the
    original document with exactly the listed entries taken out, in the same
    order. Otherwise, or on any bad input, nothing is written and the script
    prints one ``ERROR:`` line and exits 1.

Usage:
    REMOVE_IDS_JSON='["GHSA-abc"]' python3 remove_stale_suppressions.py path.toml

Environment:
    REMOVE_IDS_JSON  JSON array of vulnerability ID strings to remove
                     (required). An ID that is not in the file is skipped with
                     a note: the file already says what the cleanup wants.

Exit codes:
    0 - Success (the file was rewritten, or nothing needed to change)
    1 - Usage error, bad input, or an edit that could not be verified; the file
        is left untouched
"""

from __future__ import annotations

import json
import os
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

_TABLE = "IgnoredVulns"
_BARE_KEY = r"[A-Za-z0-9_-]+"
_BASIC_KEY = r'"(?:[^"\\\n]|\\.)*"'
_LITERAL_KEY = r"'[^'\n]*'"
_KEY = rf"(?:{_BARE_KEY}|{_BASIC_KEY}|{_LITERAL_KEY})"
_DOTTED_KEY = rf"{_KEY}(?:[ \t]*\.[ \t]*{_KEY})*"
_TRAILER = r"[ \t]*(?:#[^\r\n]*)?\r?\n?\Z"
# Any table or array-of-tables header, as TOML allows it: indentation,
# whitespace around the (dotted, quoted) key, and a trailing comment.
_ARRAY_HEADER = rf"\[\[[ \t]*{_DOTTED_KEY}[ \t]*\]\]"
_TABLE_HEADER = rf"\[[ \t]*{_DOTTED_KEY}[ \t]*\]"
_HEADER = re.compile(rf"[ \t]*(?:{_ARRAY_HEADER}|{_TABLE_HEADER}){_TRAILER}")
_IGNORED_HEADER = re.compile(
    rf"""[ \t]*\[\[[ \t]*(?:{_TABLE}|"{_TABLE}"|'{_TABLE}')[ \t]*\]\]{_TRAILER}""",
)


class RemovalError(Exception):
    """The input is unusable or the edit could not be verified."""


def split_lines(content: str) -> list[str]:
    r"""Split on ``\n`` only, keeping line endings.

    ``str.splitlines`` also splits on characters such as U+2028 that TOML
    allows inside strings, which would cut a value in two.
    """
    parts = content.split("\n")
    lines = [part + "\n" for part in parts[:-1]]
    if parts[-1]:
        lines.append(parts[-1])
    return lines


def _skip_basic_string(line: str, pos: int) -> int:
    """Return the index after the closing quote of a one-line basic string."""
    while pos < len(line) and line[pos] != '"':
        pos += 2 if line[pos] == "\\" else 1
    return pos + 1


def _scan_line(line: str, pos: int, open_string: str | None) -> str | None:
    """Return the multi-line string delimiter still open at the end of line.

    Args:
        line: One line of the file.
        pos: Index to start scanning from.
        open_string: The delimiter open at the start of the line, if any.

    Returns:
        ``'\"\"\"'`` or ``"'''"`` when a multi-line string is still open.
    """
    while pos < len(line):
        if open_string is not None:
            if open_string == '"""' and line[pos] == "\\":
                pos += 2
                continue
            if line.startswith(open_string, pos):
                pos += 3
                # Up to two more quotes belong to the string's content.
                while pos < len(line) and line[pos] == open_string[0]:
                    pos += 1
                open_string = None
                continue
            pos += 1
            continue
        char = line[pos]
        if char == "#":
            return None
        if line.startswith('"""', pos) or line.startswith("'''", pos):
            open_string = line[pos : pos + 3]
            pos += 3
        elif char == '"':
            pos = _skip_basic_string(line, pos + 1)
        elif char == "'":
            closing = line.find("'", pos + 1)
            pos = len(line) if closing < 0 else closing + 1
        else:
            pos += 1
    return open_string


def lines_outside_strings(lines: list[str]) -> list[bool]:
    """Flag the lines that do not start inside a multi-line string."""
    flags: list[bool] = []
    open_string: str | None = None
    for line in lines:
        flags.append(open_string is None)
        open_string = _scan_line(line, 0, open_string)
    return flags


def _is_comment(line: str) -> bool:
    return line.lstrip(" \t").startswith("#")


def _is_blank(line: str) -> bool:
    return not line.strip(" \t\r\n")


def _entry_id(entry: object) -> str | None:
    vuln_id = entry.get("id") if isinstance(entry, dict) else None
    return vuln_id if isinstance(vuln_id, str) else None


def _block_starts(lines: list[str], outside: list[bool]) -> list[tuple[int, bool]]:
    """Return ``(first line, is IgnoredVulns)`` for every table block.

    A block starts at the comment lines directly above its header.
    """
    starts: list[tuple[int, bool]] = []
    for index, line in enumerate(lines):
        if not outside[index] or not _HEADER.match(line):
            continue
        start = index
        while start > 0 and outside[start - 1] and _is_comment(lines[start - 1]):
            start -= 1
        starts.append((start, bool(_IGNORED_HEADER.match(line))))
    return starts


def _trailing_blank_count(lines: list[str]) -> int:
    count = 0
    while count < len(lines) and _is_blank(lines[-1 - count]):
        count += 1
    return count


def _tidy_end(out: list[str], lines: list[str]) -> list[str]:
    """Match the original file's trailing blank lines and final newline."""
    keep_blank = _trailing_blank_count(lines)
    while _trailing_blank_count(out) > keep_blank:
        out.pop()
    if out and not lines[-1].endswith("\n"):
        out[-1] = out[-1].rstrip("\r\n")
    return out


def expected_document(data: dict[str, Any], remove_ids: set[str]) -> dict[str, Any]:
    """Return ``data`` with the listed ``IgnoredVulns`` entries taken out."""
    expected = dict(data)
    kept = [item for item in data[_TABLE] if _entry_id(item) not in remove_ids]
    if kept:
        expected[_TABLE] = kept
    else:
        del expected[_TABLE]
    return expected


def canonical(value: object) -> object:
    """Return a comparable form of a parsed TOML value.

    Key order is ignored (removing the first ``[[IgnoredVulns]]`` block can
    move the array after another table without changing the document), but
    array order and value types are kept: a date never equals a string, and
    ``repr`` makes ``nan`` equal to itself.
    """
    if isinstance(value, dict):
        return tuple(sorted((key, canonical(item)) for key, item in value.items()))
    if isinstance(value, list):
        return tuple(canonical(item) for item in value)
    return (type(value).__name__, repr(value))


def verify_rewrite(rewritten: str, expected: dict[str, Any]) -> None:
    """Check that ``rewritten`` parses to exactly ``expected``.

    Raises:
        RemovalError: When the result is not TOML or means something else.
    """
    try:
        actual = tomllib.loads(rewritten)
    except tomllib.TOMLDecodeError as exc:
        raise RemovalError(f"the edited file would not be valid TOML ({exc})") from exc
    if canonical(actual) != canonical(expected):
        raise RemovalError(
            "the edited file would change more than the listed suppressions",
        )


def remove_stale_ignored_vulns(
    content: str,
    remove_ids: set[str],
) -> tuple[str, set[str]]:
    """Drop the [[IgnoredVulns]] blocks whose id is in remove_ids.

    Args:
        content: Full TOML file contents.
        remove_ids: Vulnerability IDs to remove.

    Returns:
        Tuple of rewritten content and the set of IDs actually removed.

    Raises:
        RemovalError: When ``content`` is not TOML, its headers cannot be
            matched to the entries tomllib reads, or the edit fails to verify.
    """
    try:
        data = tomllib.loads(content)
    except tomllib.TOMLDecodeError as exc:
        raise RemovalError(f"not valid TOML ({exc})") from exc

    entries = data.get(_TABLE)
    if not isinstance(entries, list):
        entries = []
    present = {vuln_id for vuln_id in map(_entry_id, entries) if vuln_id in remove_ids}
    if not present:
        return content, set()

    lines = split_lines(content)
    out = _kept_lines(lines, [_entry_id(item) in remove_ids for item in entries])
    rewritten = "".join(_tidy_end(out, lines))
    verify_rewrite(rewritten, expected_document(data, remove_ids))
    return rewritten, present


def _kept_lines(lines: list[str], drop: list[bool]) -> list[str]:
    """Return ``lines`` without the ``[[IgnoredVulns]]`` blocks marked in drop.

    Args:
        lines: The file split by :func:`split_lines`.
        drop: One flag per entry tomllib reads, in file order.

    Raises:
        RemovalError: When the header lines do not match tomllib's entries.
    """
    starts = _block_starts(lines, lines_outside_strings(lines))
    headers = sum(1 for _, ignored in starts if ignored)
    if headers != len(drop):
        raise RemovalError(
            f"found {headers} [[{_TABLE}]] header lines but tomllib reads "
            f"{len(drop)} entries; the file is not edited by line",
        )

    out = lines[: starts[0][0]]
    flags = iter(drop)
    for number, (start, ignored) in enumerate(starts):
        end = starts[number + 1][0] if number + 1 < len(starts) else len(lines)
        if not (ignored and next(flags)):
            out.extend(lines[start:end])
    return out


def read_remove_ids() -> set[str]:
    """Read ``REMOVE_IDS_JSON`` as a set of ID strings.

    Raises:
        RemovalError: When the variable is unset, not JSON, or not a list of
            strings.
    """
    raw = os.environ.get("REMOVE_IDS_JSON")
    if raw is None:
        raise RemovalError("REMOVE_IDS_JSON is not set")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RemovalError(f"REMOVE_IDS_JSON is not valid JSON ({exc})") from exc
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise RemovalError("REMOVE_IDS_JSON must be a JSON array of strings")
    return set(value)


def read_config(toml_path: Path) -> str:
    """Read the suppression file as UTF-8 without translating line endings.

    Raises:
        RemovalError: When the file cannot be read or is not UTF-8.
    """
    try:
        return toml_path.read_bytes().decode("utf-8")
    except FileNotFoundError as exc:
        raise RemovalError(f"{toml_path} does not exist") from exc
    except OSError as exc:
        raise RemovalError(f"cannot read {toml_path} ({exc.strerror})") from exc
    except UnicodeDecodeError as exc:
        raise RemovalError(f"{toml_path} is not UTF-8 ({exc.reason})") from exc


def run(toml_path: Path) -> None:
    """Remove the listed suppressions from ``toml_path``.

    Raises:
        RemovalError: On bad input or an edit that could not be verified.
    """
    remove_ids = read_remove_ids()
    original = read_config(toml_path)
    try:
        rewritten, removed = remove_stale_ignored_vulns(original, remove_ids)
    except RemovalError as exc:
        raise RemovalError(f"{toml_path}: {exc}") from exc

    if rewritten != original:
        toml_path.write_bytes(rewritten.encode("utf-8"))

    for vuln_id in sorted(removed):
        print(f"Removed: {vuln_id}", file=sys.stderr)
    for vuln_id in sorted(remove_ids - removed):
        print(f"Not in {toml_path}, nothing to remove: {vuln_id}", file=sys.stderr)


def main() -> None:
    """Entry point."""
    if len(sys.argv) != 2:
        print(
            "Usage: REMOVE_IDS_JSON='[...]' remove_stale_suppressions.py <toml-path>",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        run(Path(sys.argv[1]))
    except RemovalError as exc:
        print(f"ERROR: {exc}; the file was left unchanged", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
