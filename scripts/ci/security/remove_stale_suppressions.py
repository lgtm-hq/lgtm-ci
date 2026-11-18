#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Remove stale [[IgnoredVulns]] blocks from .osv-scanner.toml.

The file is edited line by line so untouched lines keep their exact bytes
(spacing, quoting, CRLF line endings), but ``tomllib`` decides what the file
means: the n-th ``[[IgnoredVulns]]`` header line is matched to the n-th entry
tomllib reads, and that entry's ``id`` decides whether the block goes. Only
array-of-tables blocks of ``IgnoredVulns`` are ever removed; every other
table (for example ``[[PackageOverrides]]``) stays where it is.

Block ownership:
    A block runs from its header to the next table header. Comment lines
    directly above a header, with no blank line in between, belong to that
    header's block and are removed with it, except a comment run that starts
    on the first line of the file: that is the file header, and it is never
    removed. Inside a removed block, a comment paragraph with a blank line
    directly before it and directly after it (a section comment such as
    ``# ---- Go toolchain ----``) is kept, together with the blank lines after
    it. Every other line of a removed block goes with it: its key lines, a
    comment between them or directly after the last one, and blank lines.

    The rule cannot tell what a comment is about. A note about a kept entry
    written directly above the next header goes with that next block when it
    is removed, and a note about a removed entry that is set off by blank
    lines on both sides stays. Every comment the edit deletes, whole-line or
    after a key or header (found outside strings), is printed to stderr as
    ``Removed comment line N: "<text>"`` for the caller to show to a
    reviewer. The text is JSON-quoted, so it is one ASCII line, and ``##[``
    and ``::`` are escaped so the runner cannot read it as a command.

Blank lines:
    The blank lines that end a removed block go with it, so the separator
    before the removed block now separates its neighbours. Blank lines left
    at the end of the file are trimmed to the number the original file ended
    with, and a file without a final newline keeps having none (its new last
    line loses its line ending).

Fail closed:
    Every listed ID must be in the file: the caller derives the list from the
    same file moments earlier, so a missing ID means the list is wrong. After
    editing, the result is parsed with tomllib and must equal the original
    document with exactly the listed entries taken out, with tables, arrays
    and value types compared exactly. The file is replaced atomically (a
    temporary file in the same directory, then a rename) with its mode kept;
    a symbolic link is refused. On any failure nothing is written, one
    ``ERROR:`` line is printed and the exit status is 1.

Usage:
    REMOVE_IDS_JSON='["GHSA-abc"]' python3 remove_stale_suppressions.py path.toml
    REMOVE_IDS_FILE=ids.json python3 remove_stale_suppressions.py path.toml

Environment (exactly one of them):
    REMOVE_IDS_JSON  JSON array of vulnerability ID strings to remove. Every
                     ID must be in the file.
    REMOVE_IDS_FILE  Path to a file holding that JSON array, for lists too
                     long for the environment.

Exit codes:
    0 - Success (the file was rewritten, or the list was empty)
    1 - Usage error, bad input, or an edit that could not be verified or
        written; the file is left untouched
"""

from __future__ import annotations

import json
import os
import re
import stat
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any, NamedTuple

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


class Rewrite(NamedTuple):
    """The edited file and what the edit removed."""

    content: str
    removed: set[str]
    comments: list[tuple[int, str]]


def no_commands(text: str) -> str:
    r"""Escape ``##[`` and ``::`` in JSON-quoted text.

    The runner reads ``##[cmd]`` anywhere in a log line and ``::cmd::`` at
    its start as commands. ``\u0023`` and ``\u003a`` are the same characters
    to a JSON reader, so the text still says exactly what it said.
    """
    return text.replace("##[", "#\\u0023[").replace("::", ":\\u003a")


def printable_id(vuln_id: str) -> str:
    """Return ``vuln_id`` for the log: as is, or JSON-quoted when unusual.

    A non-empty ID of printable ASCII without surrounding spaces, ``##[`` or
    ``::`` is printed as is. Anything else is JSON-quoted (see
    :func:`no_commands`), which makes it one ASCII line with no control
    characters and shows any whitespace. These lines only reach the job log;
    the pull request is built from the classifier's rows.
    """
    usual = vuln_id.isascii() and vuln_id.isprintable()
    if usual and vuln_id.strip() == vuln_id != "" and no_commands(vuln_id) == vuln_id:
        return vuln_id
    return no_commands(json.dumps(vuln_id))


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


def _scan_line(
    line: str,
    pos: int,
    open_string: str | None,
) -> tuple[str | None, int | None]:
    """Return the string still open at the end of a line, and its comment.

    Args:
        line: One line of the file.
        pos: Index to start scanning from.
        open_string: The delimiter open at the start of the line, if any.

    Returns:
        ``'\"\"\"'`` or ``"'''"`` when a multi-line string is still open,
        and the index of a comment outside strings, if the line has one.
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
            return None, pos
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
    return open_string, None


class _Scan(NamedTuple):
    """Per line: whether it starts outside strings, and where its comment is."""

    outside: list[bool]
    comment_at: list[int | None]


def scan_lines(lines: list[str]) -> _Scan:
    """Scan every line for multi-line strings and comments."""
    scan = _Scan([], [])
    open_string: str | None = None
    for line in lines:
        scan.outside.append(open_string is None)
        open_string, comment = _scan_line(line, 0, open_string)
        scan.comment_at.append(comment)
    return scan


def lines_outside_strings(lines: list[str]) -> list[bool]:
    """Flag the lines that do not start inside a multi-line string."""
    return scan_lines(lines).outside


def _is_comment(line: str) -> bool:
    """Tell whether ``line`` is a TOML comment."""
    return line.lstrip(" \t").startswith("#")


def _is_blank(line: str) -> bool:
    """Tell whether ``line`` holds only whitespace."""
    return not line.strip(" \t\r\n")


def _entry_id(entry: object) -> str | None:
    """Return the entry's ``id`` when it is a string, else None."""
    vuln_id = entry.get("id") if isinstance(entry, dict) else None
    return vuln_id if isinstance(vuln_id, str) else None


class _Block(NamedTuple):
    """One table block: its first line, its header line, and its kind."""

    start: int
    header: int
    ignored: bool


def _blocks(lines: list[str], outside: list[bool]) -> list[_Block]:
    """Return every table block in file order.

    A block starts at the comment lines directly above its header, unless
    that comment run starts on the first line of the file (the file header).
    """
    blocks: list[_Block] = []
    for index, line in enumerate(lines):
        if not outside[index] or not _HEADER.match(line):
            continue
        start = index
        while start > 0 and outside[start - 1] and _is_comment(lines[start - 1]):
            start -= 1
        if start == 0:
            start = index
        blocks.append(_Block(start, index, bool(_IGNORED_HEADER.match(line))))
    return blocks


def _comment_run_end(
    lines: list[str],
    outside: list[bool],
    index: int,
    end: int,
) -> int:
    """Return the index after the comment run that starts at ``index``."""
    while index < end and outside[index] and _is_comment(lines[index]):
        index += 1
    return index


def _split_removed(
    lines: list[str],
    scan: _Scan,
    block: _Block,
    end: int,
) -> tuple[list[str], list[tuple[int, str]]]:
    """Split a removed block into the lines it keeps and the comments it loses.

    Returns:
        The section comments kept (each with the blank lines after it), and
        ``(line number, text)`` for every comment removed: whole comment
        lines, and the comment after a key or header on a removed line.
    """
    kept: list[str] = []
    lost: list[tuple[int, str]] = []
    index = block.start
    while index < end:
        run_end = _comment_run_end(lines, scan.outside, index, end)
        if run_end == index:
            at = scan.comment_at[index]
            if at is not None:
                lost.append((index + 1, lines[index][at:].rstrip("\r\n")))
            index += 1
            continue
        section = (
            index > block.header
            and _is_blank(lines[index - 1])
            and run_end < end
            and _is_blank(lines[run_end])
        )
        if section:
            after = run_end
            while after < end and _is_blank(lines[after]):
                after += 1
            kept.extend(lines[index:after])
            run_end = after
        else:
            for number in range(index, run_end):
                lost.append((number + 1, lines[number].rstrip("\r\n")))
        index = run_end
    return kept, lost


def _kept_lines(
    lines: list[str],
    drop: list[bool],
) -> tuple[list[str], list[tuple[int, str]]]:
    """Return ``lines`` without the ``[[IgnoredVulns]]`` blocks marked in drop.

    Args:
        lines: The file split by :func:`split_lines`.
        drop: One flag per entry tomllib reads, in file order.

    Returns:
        The kept lines, and the comment lines removed with their numbers.

    Raises:
        RemovalError: When the header lines do not match tomllib's entries.
    """
    scan = scan_lines(lines)
    blocks = _blocks(lines, scan.outside)
    headers = sum(1 for block in blocks if block.ignored)
    if headers != len(drop):
        raise RemovalError(
            f"found {headers} [[{_TABLE}]] header lines but tomllib reads "
            f"{len(drop)} entries; refusing to edit the file by line",
        )

    out = lines[: blocks[0].start]
    lost: list[tuple[int, str]] = []
    flags = iter(drop)
    for number, block in enumerate(blocks):
        end = blocks[number + 1].start if number + 1 < len(blocks) else len(lines)
        if block.ignored and next(flags):
            kept, removed = _split_removed(lines, scan, block, end)
            out.extend(kept)
            lost.extend(removed)
        else:
            out.extend(lines[block.start : end])
    return out, lost


def _trailing_blank_count(lines: list[str]) -> int:
    """Count the blank lines at the end of ``lines``."""
    count = 0
    while count < len(lines) and _is_blank(lines[-1 - count]):
        count += 1
    return count


def _tidy_end(out: list[str], lines: list[str]) -> list[str]:
    """Match the original file's trailing blank lines and final newline."""
    extra = _trailing_blank_count(out) - _trailing_blank_count(lines)
    if extra > 0:
        del out[-extra:]
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

    Tables and arrays are tagged so an empty table never equals an empty
    array. Key order is ignored (removing the first ``[[IgnoredVulns]]``
    block can move the array after another table without changing the
    document), but array order and value types are kept: ``1``, ``1.0`` and
    ``"1"`` differ, a date never equals a string, and ``repr`` makes ``nan``
    equal to itself.
    """
    if isinstance(value, dict):
        items = sorted((key, canonical(item)) for key, item in value.items())
        return ("table", tuple(items))
    if isinstance(value, list):
        return ("array", tuple(canonical(item) for item in value))
    return (type(value).__name__, repr(value))


def parse_toml(content: str, what: str) -> dict[str, Any]:
    """Parse ``content`` or raise a :class:`RemovalError` naming ``what``."""
    try:
        return tomllib.loads(content)
    except ValueError as exc:  # TOMLDecodeError, or an integer too long to read
        raise RemovalError(f"{what} ({exc})") from exc
    except RecursionError as exc:
        raise RemovalError(f"{what} (nested too deeply to read)") from exc


def verify_rewrite(rewritten: str, expected: dict[str, Any]) -> None:
    """Check that ``rewritten`` parses to exactly ``expected``.

    Raises:
        RemovalError: When the result is not TOML or means something else.
    """
    actual = parse_toml(rewritten, "the edited file would not be valid TOML")
    try:
        same = canonical(actual) == canonical(expected)
    except RecursionError as exc:
        raise RemovalError("the file is nested too deeply to verify an edit") from exc
    if not same:
        raise RemovalError(
            "the edited file would change more than the listed suppressions",
        )


def remove_stale_ignored_vulns(content: str, remove_ids: set[str]) -> Rewrite:
    """Drop the [[IgnoredVulns]] blocks whose id is in remove_ids.

    Args:
        content: Full TOML file contents.
        remove_ids: Vulnerability IDs to remove; every one must be in the file.

    Returns:
        The rewritten content, the IDs removed, and the comment lines removed.

    Raises:
        RemovalError: When ``content`` is not TOML, a listed ID is not in it,
            its headers cannot be matched to the entries tomllib reads, or the
            edit fails to verify.
    """
    data = parse_toml(content, "not valid TOML")
    entries = data.get(_TABLE)
    if not isinstance(entries, list):
        entries = []
    missing = remove_ids - {_entry_id(item) for item in entries}
    if missing:
        names = ", ".join(printable_id(vuln_id) for vuln_id in sorted(missing))
        raise RemovalError(
            f"REMOVE_IDS_JSON lists {len(missing)} ID(s) that are not in the "
            f"file ({names}); the list does not match the file",
        )
    if not remove_ids:
        return Rewrite(content, set(), [])

    lines = split_lines(content)
    drop = [_entry_id(item) in remove_ids for item in entries]
    out, comments = _kept_lines(lines, drop)
    rewritten = "".join(_tidy_end(out, lines))
    verify_rewrite(rewritten, expected_document(data, remove_ids))
    return Rewrite(rewritten, set(remove_ids), comments)


def _remove_ids_source() -> tuple[str, str]:
    """Return the name and text of the ID list, from the variable or file.

    Raises:
        RemovalError: When neither or both are set, or the file is unreadable.
    """
    inline = os.environ.get("REMOVE_IDS_JSON")
    path = os.environ.get("REMOVE_IDS_FILE")
    if inline is not None and path is not None:
        raise RemovalError("set REMOVE_IDS_JSON or REMOVE_IDS_FILE, not both")
    if inline is not None:
        return "REMOVE_IDS_JSON", inline
    if path is None:
        raise RemovalError("REMOVE_IDS_JSON or REMOVE_IDS_FILE must be set")
    try:
        return "REMOVE_IDS_FILE", Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise RemovalError(f"cannot read REMOVE_IDS_FILE ({exc})") from exc


def read_remove_ids() -> set[str]:
    """Read the IDs to remove (see the module docstring) as a set of strings.

    Raises:
        RemovalError: When the list is missing, not JSON, or not a list of
            strings.
    """
    name, raw = _remove_ids_source()
    try:
        value = json.loads(raw)
    except ValueError as exc:  # JSONDecodeError, or an integer too long to read
        raise RemovalError(f"{name} is not valid JSON ({exc})") from exc
    except RecursionError as exc:
        raise RemovalError(f"{name} is nested too deeply to read") from exc
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise RemovalError(f"{name} must be a JSON array of strings")
    return set(value)


def read_config(toml_path: Path) -> str:
    """Read the suppression file as UTF-8 without translating line endings.

    Raises:
        RemovalError: When the file is a symbolic link, cannot be read, or is
            not UTF-8.
    """
    if toml_path.is_symlink():
        raise RemovalError(f"{toml_path} is a symbolic link; refusing to replace it")
    try:
        return toml_path.read_bytes().decode("utf-8")
    except FileNotFoundError as exc:
        raise RemovalError(f"{toml_path} does not exist") from exc
    except OSError as exc:
        raise RemovalError(f"cannot read {toml_path} ({exc.strerror})") from exc
    except UnicodeDecodeError as exc:
        raise RemovalError(f"{toml_path} is not UTF-8 ({exc.reason})") from exc


def write_atomically(path: Path, data: bytes) -> None:
    """Replace ``path`` with ``data`` through a temporary sibling file.

    The temporary file is written, flushed and synced, given the original
    file's mode, then renamed over ``path``. On any failure it is removed and
    ``path`` is left as it was.

    Raises:
        RemovalError: When the temporary file cannot be created or written,
            or the rename fails.
    """
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
        handle, name = tempfile.mkstemp(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
        )
    except OSError as exc:
        message = f"cannot create a temporary file for {path} ({exc})"
        raise RemovalError(message) from exc
    temporary = Path(name)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        raise RemovalError(f"cannot write {path} ({exc})") from exc


def run(toml_path: Path) -> None:
    """Remove the listed suppressions from ``toml_path``.

    Raises:
        RemovalError: On bad input or an edit that could not be verified or
            written.
    """
    remove_ids = read_remove_ids()
    original = read_config(toml_path)
    try:
        result = remove_stale_ignored_vulns(original, remove_ids)
    except RemovalError as exc:
        raise RemovalError(f"{toml_path}: {exc}") from exc

    if result.content != original:
        write_atomically(toml_path, result.content.encode("utf-8"))

    for vuln_id in sorted(result.removed):
        print(f"Removed: {printable_id(vuln_id)}", file=sys.stderr)
    for number, text in result.comments:
        quoted = no_commands(json.dumps(text))
        print(f"Removed comment line {number}: {quoted}", file=sys.stderr)


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
