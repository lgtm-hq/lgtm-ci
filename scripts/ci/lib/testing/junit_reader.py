#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Read untrusted JUnit XML into test counts and expected failures (#1686).

Runs as ``python3 -I`` from the tooling checkout on any runner ``python3``:
standard library only, Python 3.10 syntax.

Commands (JSON on stdout, exit 0; exit 2 on a usage error):

``leg <dir> <glob>``
    Every regular file under ``<dir>`` matching ``<glob>`` (relative, no
    ``..``), summed: ``{"status": "ok", "files": n, "counts": {...},
    "expected_failures": [{"id", "reason"}, ...]}``. Any file that is
    unreadable, over a limit, or whose totals disagree with its cases makes
    the whole leg ``{"status": "unreadable", "reason": "..."}``; no match is
    ``{"status": "missing", ...}``.
``reasons <file>``
    ``{"status": "ok", "reasons": {"<classname>::<name>": "<message>"}}`` for
    the expected failures of one file; an id listed twice with different
    reasons is left out.

Mapping per ``<testcase>``: a ``<failure>`` or ``<error>`` child is failed;
else ``<skipped type="pytest.xfail">`` is an expected failure (reason: its
``message``); else any ``<skipped>`` is skipped; else passed. pytest writes a
test that failed in its call and errored in teardown as two testcases with
one id, one after the other, so a testcase that directly follows one with the
same non-empty id is the same test, the worst outcome kept.

Safety: the file is read only up to a size limit, must be UTF-8 (strict), and
is refused when its prolog declares a DOCTYPE or an entity. The parser is
expat itself (what ElementTree uses underneath) with handlers that abort on
any DOCTYPE, entity declaration or external entity reference, parameter
entities off; so no entity is ever declared, expanded or fetched. Nesting
depth and the number of test cases are limited too.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn
from xml.parsers import expat

MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_LEG_BYTES = 64 * 1024 * 1024
MAX_FILES = 1000
MAX_CASES = 50_000
MAX_DEPTH = 32
#: One character over results.v1's 500, so the builder still marks the cut.
MAX_TEXT_CHARS = 501
_COUNT = re.compile(r"[0-9]{1,9}")
_PROLOG_DECL = re.compile(r"<!\s*(?:DOCTYPE|ENTITY)", re.IGNORECASE)
_FIRST_ELEMENT = re.compile(r"<[A-Za-z_:]")
_ENCODING_DECL = re.compile(r"""^<\?xml[^>]*\bencoding\s*=\s*["']([^"']*)["']""")
_UTF8_NAMES = {"utf-8", "utf8", "us-ascii", "ascii"}
_UNSAFE_NAME = re.compile(r"[^A-Za-z0-9._/ +@=:<>()-]")
#: Outcome ranks; the highest seen for one id wins.
_PASSED, _SKIPPED, _XFAILED, _FAILED = 0, 1, 2, 3
_SUITES = ("testsuite", "testsuites")
_CASE_CHILDREN = ("failure", "error", "skipped")
_TOTALS = (("failures", "failure"), ("errors", "error"), ("skipped", "skipped"))


class Unreadable(Exception):
    """The report cannot give trustworthy counts."""


def _safe_name(text: str) -> str:
    """Return ``text`` fit for a job log line (no newlines, no markup)."""
    return _UNSAFE_NAME.sub("?", text)[:200]


def _count_attr(attrs: dict[str, str], name: str) -> int | None:
    """Return a count attribute, None when absent; raise when malformed."""
    value = attrs.get(name)
    if value is None:
        return None
    if not _COUNT.fullmatch(value.strip()):
        raise Unreadable(f"{name} is not a whole number of at most nine digits")
    return int(value)


@dataclass
class _Case:
    """One test: its id, outcome rank and expected-failure reason."""

    case_id: str
    rank: int = _PASSED
    reason: str = ""


class _Suite:
    """Counts of one ``<testsuite>``/``<testsuites>`` element and its subtree."""

    def __init__(self, attrs: dict[str, str]) -> None:
        self.attrs = attrs
        self.cases: list[_Case] = []
        self.elements = 0
        self.children = {"failure": 0, "error": 0, "skipped": 0}
        self.nested_distinct = 0
        self.nested_outcomes = [0, 0, 0, 0]

    def outcomes(self) -> list[int]:
        """Return passed, skipped, xfailed, failed over the subtree."""
        own = [0, 0, 0, 0]
        for case in self.cases:
            own[case.rank] += 1
        return [a + b for a, b in zip(own, self.nested_outcomes, strict=False)]

    def check(self) -> None:
        """Raise when a present total attribute disagrees with the cases."""
        distinct = len(self.cases) + self.nested_distinct
        tests = _count_attr(self.attrs, "tests")
        if tests is not None and tests not in (distinct, self.elements):
            raise Unreadable(
                f"tests={tests} but the report holds {distinct} test case(s)",
            )
        for attr, kind in _TOTALS:
            value = _count_attr(self.attrs, attr)
            held = self.children[kind]
            if value is not None and value != held:
                raise Unreadable(f"{attr}={value} but the report holds {held}")


class _Reader:
    """Expat handlers that count one report."""

    def __init__(self, budget: list[int]) -> None:
        self.budget = budget
        self.stack: list[str] = []
        self.suites: list[_Suite] = []
        self.case: _Case | None = None
        self.root_seen = False
        self.result = [0, 0, 0, 0]
        self.xfails: list[tuple[str, str]] = []

    def start(self, name: str, attrs: dict[str, str]) -> None:
        """Handle an element start."""
        parent = self.stack[-1] if self.stack else None
        self.stack.append(name)
        if len(self.stack) > MAX_DEPTH:
            raise Unreadable(f"elements nested deeper than {MAX_DEPTH}")
        if parent is None:
            if name not in _SUITES:
                shown = _safe_name(name)
                raise Unreadable(f"root element <{shown}> is not a test suite")
            self.root_seen = True
        if name in _SUITES:
            if parent is not None and parent not in _SUITES:
                raise Unreadable("a test suite inside a test case")
            self.suites.append(_Suite(attrs))
        elif name == "testcase":
            if parent != "testsuite":
                raise Unreadable("a test case outside a <testsuite>")
            self.budget[0] -= 1
            if self.budget[0] < 0:
                raise Unreadable(f"more than {MAX_CASES} test cases")
            classname, case_name = attrs.get("classname", ""), attrs.get("name", "")
            case_id = f"{classname}::{case_name}" if classname else case_name
            self.case = _Case(case_id)
        elif parent == "testcase" and name in _CASE_CHILDREN:
            # A testcase parent is always the open case: testcases are only
            # opened under a <testsuite>, so start() set self.case for it.
            self._case_child(name, attrs)

    def _case_child(self, name: str, attrs: dict[str, str]) -> None:
        """Record a failure, error or skipped child of the open test case."""
        self.suites[-1].children[name] += 1
        rank = _FAILED
        reason = ""
        if name == "skipped":
            xfail = attrs.get("type") == "pytest.xfail"
            rank = _XFAILED if xfail else _SKIPPED
            reason = attrs.get("message", "")[:MAX_TEXT_CHARS] if xfail else ""
        if self.case is not None and rank > self.case.rank:
            self.case.rank, self.case.reason = rank, reason

    def end(self, name: str) -> None:
        """Handle an element end."""
        self.stack.pop()
        if name == "testcase" and self.case is not None:
            suite, case = self.suites[-1], self.case
            suite.elements += 1
            last = suite.cases[-1] if suite.cases else None
            if last is None or not case.case_id or last.case_id != case.case_id:
                suite.cases.append(case)
            elif case.rank > last.rank:
                last.rank, last.reason = case.rank, case.reason
            self.case = None
        elif name in _SUITES:
            suite = self.suites.pop()
            suite.check()
            for case in suite.cases:
                if case.rank == _XFAILED:
                    self.xfails.append((case.case_id, case.reason))
            outcomes = suite.outcomes()
            if self.suites:
                parent = self.suites[-1]
                parent.nested_distinct += len(suite.cases) + suite.nested_distinct
                nested = zip(parent.nested_outcomes, outcomes, strict=False)
                parent.nested_outcomes = [a + b for a, b in nested]
                parent.elements += suite.elements
                for kind, count in suite.children.items():
                    parent.children[kind] += count
            else:
                self.result = outcomes


def _refuse(*_args: object) -> NoReturn:
    """Expat handler: abort on any DOCTYPE, entity declaration or reference.

    Raises:
        Unreadable: Always.
    """
    raise Unreadable("the report declares a DOCTYPE or an entity")


def _decode(raw: bytes) -> None:
    """Raise unless ``raw`` is strict UTF-8 with no DOCTYPE or entity in its prolog."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Unreadable(f"not UTF-8 (byte {error.start})") from None
    text = text.removeprefix("\ufeff")
    declared = _ENCODING_DECL.match(text)
    if declared and declared.group(1).strip().lower() not in _UTF8_NAMES:
        raise Unreadable("the report declares an encoding other than UTF-8")
    first = _FIRST_ELEMENT.search(text)
    prolog = text[: first.start()] if first else text
    if _PROLOG_DECL.search(prolog):
        raise Unreadable("the report declares a DOCTYPE or an entity")


def read_report(path: Path, budget: list[int]) -> _Reader:
    """Count one JUnit file; raise Unreadable on any problem."""
    with path.open("rb") as handle:
        raw = handle.read(MAX_FILE_BYTES + 1)
    if len(raw) > MAX_FILE_BYTES:
        raise Unreadable(f"larger than {MAX_FILE_BYTES} bytes")
    _decode(raw)
    reader = _Reader(budget)
    parser = expat.ParserCreate(encoding="UTF-8")
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    # Typed loosely: each handler slot has its own signature, and _refuse
    # takes any arguments because it only ever raises.
    refuse: Any = _refuse
    parser.StartDoctypeDeclHandler = refuse
    parser.EntityDeclHandler = refuse
    parser.UnparsedEntityDeclHandler = refuse
    parser.ExternalEntityRefHandler = refuse
    parser.SkippedEntityHandler = refuse
    parser.StartElementHandler = reader.start
    parser.EndElementHandler = reader.end
    try:
        parser.Parse(raw, True)
    except expat.ExpatError as error:
        raise Unreadable(f"not well-formed XML (line {error.lineno})") from None
    if not reader.root_seen:
        raise Unreadable("no test suite element")
    return reader


def _matches(root: Path, pattern: str) -> list[Path]:
    """Return the regular files under ``root`` matching ``pattern``, sorted."""
    if not pattern or pattern.startswith("/") or ".." in Path(pattern).parts:
        raise ValueError("junit-path must be a relative glob without '..'")
    base = root.resolve()
    found: list[Path] = []
    for match in sorted(root.glob(pattern)):
        if match.is_symlink():
            shown = _safe_name(str(match.relative_to(root)))
            raise Unreadable(f"{shown} is a symbolic link")
        if match.is_file() and match.resolve().is_relative_to(base):
            found.append(match)
    return found


def _sum_reports(
    root: Path,
    files: list[Path],
) -> tuple[list[int], list[dict[str, str]]]:
    """Add up ``files``; raise Unreadable naming the first file that fails."""
    budget = [MAX_CASES]
    size = 0
    totals = [0, 0, 0, 0]
    xfails: list[dict[str, str]] = []
    for path in files:
        name = _safe_name(str(path.relative_to(root)))
        try:
            size += path.stat().st_size
            if size > MAX_LEG_BYTES:
                raise Unreadable(f"the reports exceed {MAX_LEG_BYTES} bytes together")
            reader = read_report(path, budget)
        except (Unreadable, OSError) as error:
            raise Unreadable(f"{name}: {error}") from None
        totals = [a + b for a, b in zip(totals, reader.result, strict=False)]
        for case_id, reason in reader.xfails:
            xfails.append({"id": case_id[:MAX_TEXT_CHARS], "reason": reason})
    return totals, xfails


def leg(root: Path, pattern: str) -> dict[str, object]:
    """Sum every matching report under ``root`` into one leg."""
    try:
        files = _matches(root, pattern)
    except Unreadable as error:
        return {"status": "unreadable", "reason": _safe_name(str(error))}
    if not files:
        return {"status": "missing", "reason": "no file matches junit-path"}
    if len(files) > MAX_FILES:
        return {"status": "unreadable", "reason": f"more than {MAX_FILES} report files"}
    try:
        totals, xfails = _sum_reports(root, files)
    except Unreadable as error:
        return {"status": "unreadable", "reason": _safe_name(str(error))}
    passed, skipped, xfailed, failed = totals
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
        "expected_failures": xfails,
    }


def reasons(path: Path) -> dict[str, object]:
    """Return the expected-failure reasons of one report by test id."""
    try:
        reader = read_report(path, [MAX_CASES])
    except (Unreadable, OSError) as error:
        return {"status": "unreadable", "reason": _safe_name(str(error))}
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
        try:
            result = leg(Path(argv[1]), argv[2])
        except ValueError as error:
            print(f"junit_reader: {error}", file=sys.stderr)
            return 2
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
