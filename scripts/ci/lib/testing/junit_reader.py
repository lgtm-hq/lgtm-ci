#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Read untrusted JUnit XML into test counts and expected failures (#1686).

Runs as ``python3 -I`` from the tooling checkout on any runner ``python3``:
standard library only, Python 3.10 syntax. The per-file parsing, mapping and
XML safety are in ``junit_cases.py`` beside it.

Commands (JSON on stdout, exit 0; exit 2 on a usage error):

``leg <dir> <glob>``
    Every regular file under ``<dir>`` matching ``<glob>`` (``/``-separated,
    ``*``, ``?``, ``[...]`` within a name, ``**`` for any depth), summed:
    ``{"status": "ok", "files": n, "counts": {...}, "expected_failures":
    [{"id", "reason"}, ...], "expected_failures_omitted": n}``. Any file that
    is unreadable, over a limit, or whose totals disagree with its cases, a
    symbolic link anywhere in ``<dir>``, or a walk over the entry or file
    limit makes the whole leg ``{"status": "unreadable", "reason": ...}``. No
    matching file is ``{"status": "missing", ...}``; a glob that is empty,
    absolute, or has an empty, ``.`` or ``..`` part is ``{"status":
    "bad-path", ...}``.
``reasons <file>``
    ``{"status": "ok", "reasons": {"<classname>::<name>": "<message>"}}`` for
    the expected failures of one file; an id listed twice with different
    reasons is left out.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

HERE = str(Path(__file__).resolve().parent)
if HERE not in sys.path:  # python3 -I leaves this directory off sys.path
    sys.path.insert(0, HERE)

# pylint: disable=wrong-import-position
import junit_cases  # noqa: E402
from junit_cases import Unreadable, safe_name  # noqa: E402

# pylint: enable=wrong-import-position

MAX_LEG_BYTES = 64 * 1024 * 1024
MAX_FILES = 1000
#: Directory entries (files and directories) one artifact walk may visit.
MAX_ENTRIES = 20_000
#: Expected failures emitted per leg: twice what results.v1 keeps (50); the
#: rest are only counted, in expected_failures_omitted.
MAX_LISTED = 100


_BAD_PATH = "junit-path must be a relative glob without empty, '.' or '..' parts"


class BadPath(Exception):
    """junit-path cannot name files inside the artifact."""


def _segment(part: str) -> str:
    """Return the regular expression of one glob path segment."""
    out: list[str] = []
    index = 0
    while index < len(part):
        char = part[index]
        closing = part.find("]", index + 2) if char == "[" else -1
        if char == "*":
            out.append("[^/]*")
        elif char == "?":
            out.append("[^/]")
        elif closing > 0:
            body = part[index + 1 : closing]
            negate = body.startswith("!")
            body = re.escape(body[1:] if negate else body).replace("\\-", "-")
            out.append(f"[{'^' if negate else ''}{body}]")
            index = closing
        else:
            out.append(re.escape(char))
        index += 1
    return "".join(out)


def glob_regex(pattern: str) -> re.Pattern[str]:
    """Compile ``pattern`` to a regular expression over relative paths."""
    parts = pattern.split("/")
    bad_part = any(part in ("", ".", "..") for part in parts)
    if not pattern or pattern.startswith("/") or bad_part:
        raise BadPath(_BAD_PATH)
    out: list[str] = []
    for index, part in enumerate(parts):
        last = index == len(parts) - 1
        if part == "**":
            out.append(".*" if last else "(?:[^/]+/)*")
        else:
            out.append(_segment(part) + ("" if last else "/"))
    return re.compile("".join(out))


def _entries(directory: Path, seen: list[int]) -> list[os.DirEntry[str]]:
    """Return one directory's entries by name, counting them against the limit."""
    entries: list[os.DirEntry[str]] = []
    with os.scandir(directory) as listing:
        for entry in listing:
            seen[0] += 1
            if seen[0] > MAX_ENTRIES:
                raise Unreadable(f"the artifact holds more than {MAX_ENTRIES} entries")
            entries.append(entry)
    return sorted(entries, key=lambda entry: entry.name)


def matches(root: Path, pattern: str) -> tuple[list[Path], bool]:
    """Return the matching regular files, sorted, and whether a directory matched.

    The walk stops at the first symbolic link, past ``MAX_ENTRIES`` entries,
    or past ``MAX_FILES`` matching files.
    """
    regex = glob_regex(pattern)
    found: list[tuple[str, Path]] = []
    directory_matched = False
    seen = [0]
    pending: list[tuple[str, Path]] = [("", root)]
    while pending:
        prefix, directory = pending.pop()
        for entry in _entries(directory, seen):
            relative = prefix + entry.name
            if entry.is_symlink():
                raise Unreadable(f"{safe_name(relative)} is a symbolic link")
            if entry.is_dir(follow_symlinks=False):
                directory_matched = directory_matched or bool(regex.fullmatch(relative))
                pending.append((relative + "/", Path(entry.path)))
            elif entry.is_file(follow_symlinks=False) and regex.fullmatch(relative):
                found.append((relative, Path(entry.path)))
                if len(found) > MAX_FILES:
                    raise Unreadable(f"more than {MAX_FILES} report files")
    return [path for _relative, path in sorted(found)], directory_matched


def _sum_reports(
    root: Path,
    files: list[Path],
) -> tuple[list[int], list[dict[str, str]]]:
    """Add up ``files``; raise Unreadable naming the first file that fails."""
    budget = [junit_cases.MAX_CASES]
    size = 0
    totals = [0, 0, 0, 0]
    xfails: list[dict[str, str]] = []
    for path in files:
        name = safe_name(str(path.relative_to(root)))
        try:
            size += path.stat().st_size
            if size > MAX_LEG_BYTES:
                raise Unreadable(f"the reports exceed {MAX_LEG_BYTES} bytes together")
            reader = junit_cases.read_report(path, budget)
        except (Unreadable, OSError) as error:
            raise Unreadable(f"{name}: {error}") from None
        totals = [a + b for a, b in zip(totals, reader.result, strict=True)]
        limit = junit_cases.MAX_TEXT_CHARS
        for case_id, reason in reader.xfails:
            xfails.append({"id": case_id[:limit], "reason": reason})
    return totals, xfails


def leg(root: Path, pattern: str) -> dict[str, object]:
    """Sum every matching report under ``root`` into one leg."""
    try:
        files, directory_matched = matches(root, pattern)
        if not files:
            what = "only directories" if directory_matched else "no file"
            return {"status": "missing", "reason": f"junit-path matches {what}"}
        totals, xfails = _sum_reports(root, files)
    except BadPath as error:
        return {"status": "bad-path", "reason": str(error)}
    except (Unreadable, OSError) as error:
        return {"status": "unreadable", "reason": safe_name(str(error))}
    passed, skipped, xfailed, failed = (
        totals[junit_cases.PASSED],
        totals[junit_cases.SKIPPED],
        totals[junit_cases.XFAILED],
        totals[junit_cases.FAILED],
    )
    return {
        "status": "ok",
        "files": len(files),
        "counts": {
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "xfailed": xfailed,
            "total": passed + failed + skipped + xfailed,
        },
        "expected_failures": xfails[:MAX_LISTED],
        "expected_failures_omitted": max(len(xfails) - MAX_LISTED, 0),
    }


def reasons(path: Path) -> dict[str, object]:
    """Return the expected-failure reasons of one report by test id."""
    try:
        reader = junit_cases.read_report(path, [junit_cases.MAX_CASES])
    except (Unreadable, OSError) as error:
        return {"status": "unreadable", "reason": safe_name(str(error))}
    found: dict[str, str] = {}
    ambiguous: set[str] = set()
    for case_id, reason in reader.xfails:
        if case_id in found and found[case_id] != reason:
            ambiguous.add(case_id)
        found.setdefault(case_id, reason)
    kept = {key: value for key, value in found.items() if key not in ambiguous}
    return {"status": "ok", "reasons": kept}


def main(argv: list[str]) -> int:
    """Run one command; see the module docstring."""
    if len(argv) == 3 and argv[0] == "leg":
        result = leg(Path(argv[1]), argv[2])
    elif len(argv) == 2 and argv[0] == "reasons":
        result = reasons(Path(argv[1]))
    else:
        usage = "usage: junit_reader.py leg <dir> <glob> | reasons <file>"
        print(usage, file=sys.stderr)
        return 2
    json.dump(result, sys.stdout, ensure_ascii=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
