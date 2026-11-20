#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Count the test cases of one untrusted JUnit XML file (#1686).

Loaded by ``junit_reader.py`` (``python3 -I``) through its ``sys.path``
fallback: standard library only, Python 3.10 syntax.

Mapping per ``<testcase>``: one or more ``<failure>`` or ``<error>`` children
make it one failed test; else ``<skipped type="pytest.xfail">`` is an expected
failure (reason: its ``message``); else any ``<skipped>`` is skipped; else
passed. A suite's ``failures``, ``errors`` and ``skipped`` must each equal
either the number of test cases with such a child or the number of those
child elements (googletest writes one ``<failure>`` per failed assertion), and
``tests`` the number of tests.

pytest writes a test that failed in its call and errored in teardown as two
testcases with one id: the first with a ``<failure>``, the second, directly
after it, with only an ``<error>``. That exact pair is one test, unless the
``tests`` attribute of the suite that holds it counts both. An enclosing
suite whose ``tests`` counts both halves of a pair its nested suite merged
makes the report unreadable. Any other repeated id is another test.

Safety, in two layers. First, before parsing: the file is read only up to a
size limit, must be strict UTF-8 without a NUL byte (so UTF-16 and UTF-32 are
refused, with or without a byte-order mark), may declare no other encoding,
and is refused when its prolog (comments and processing instructions skipped)
holds a markup declaration such as a DOCTYPE or an entity. Second, the parser
is expat itself (what ElementTree uses underneath) with handlers that abort on
any DOCTYPE, entity declaration or external entity reference, parameter
entities off; so no entity is ever declared, expanded or fetched. Nesting
depth and the number of test cases are limited too.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, NoReturn
from xml.parsers import expat

MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_DEPTH = 32
#: Test cases per artifact (leg), shared across its files.
MAX_CASES = 50_000
#: One character over results.v1's 500, so the builder still marks the cut.
MAX_TEXT_CHARS = 501
_COUNT = re.compile(r"[0-9]{1,9}")
_ENCODING_DECL = re.compile(r"""^<\?xml[^>]*\bencoding\s*=\s*["']([^"']*)["']""")
_UTF8_NAMES = {"utf-8", "utf8", "us-ascii", "ascii"}
_UNSAFE_NAME = re.compile(r"[^A-Za-z0-9._/ +@=:<>()-]")
#: Outcome ranks; the highest seen in one test case wins.
PASSED, SKIPPED, XFAILED, FAILED = 0, 1, 2, 3
_SUITES = ("testsuite", "testsuites")
_KINDS = ("failure", "error", "skipped")
_TOTALS = (("failures", "failure"), ("errors", "error"), ("skipped", "skipped"))
_DECLARED = "the report declares a DOCTYPE or an entity"


class Unreadable(Exception):
    """The report cannot give trustworthy counts."""


def safe_name(text: str) -> str:
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
    """One ``<testcase>``: id, outcome rank, reason and the child kinds seen."""

    case_id: str
    rank: int = PASSED
    reason: str = ""
    kinds: set[str] = field(default_factory=set)
    #: pytest's teardown error of the test case just before it.
    teardown: bool = False


class _Suite:
    """Counts of one ``<testsuite>``/``<testsuites>`` element and its subtree."""

    def __init__(self, attrs: dict[str, str]) -> None:
        self.attrs = attrs
        self.cases: list[_Case] = []
        self.child_elements = dict.fromkeys(_KINDS, 0)
        self.child_cases = dict.fromkeys(_KINDS, 0)
        self.nested_tests = 0
        self.nested_outcomes = [0, 0, 0, 0]

    def add_case(self, case: _Case) -> None:
        """Record a closed test case, marking pytest's teardown-error repeat."""
        for kind in case.kinds:
            self.child_cases[kind] += 1
        last = self.cases[-1] if self.cases else None
        case.teardown = bool(
            last is not None
            and case.case_id
            and last.case_id == case.case_id
            and not last.teardown
            and "failure" in last.kinds
            and case.kinds == {"error"},
        )
        self.cases.append(case)

    def close(self) -> list[_Case]:
        """Check the totals and return the tests, pytest pairs merged."""
        tests = _count_attr(self.attrs, "tests")
        merged = [case for case in self.cases if not case.teardown]
        if tests is not None and tests != len(merged) + self.nested_tests:
            merged = self.cases
        counted = len(merged) + self.nested_tests
        # A total that counts both halves of a pair a nested suite already
        # merged is refused like any other mismatch: accepting it would
        # report fewer failures than the report declares.
        if tests is not None and tests != counted:
            raise Unreadable(f"tests={tests} but the report holds {counted} test(s)")
        for attr, kind in _TOTALS:
            value = _count_attr(self.attrs, attr)
            allowed = (self.child_cases[kind], self.child_elements[kind])
            if value is not None and value not in allowed:
                raise Unreadable(
                    f"{attr}={value} but the report holds {allowed[0]} test case(s)"
                    f" with {allowed[1]} <{kind}> element(s)",
                )
        return merged

    def absorb(self, child: _Suite, tests: list[_Case]) -> None:
        """Add a closed nested suite's counts to this one."""
        self.nested_tests += len(tests) + child.nested_tests
        own = [0, 0, 0, 0]
        for case in tests:
            own[case.rank] += 1
        sources = zip(self.nested_outcomes, own, child.nested_outcomes, strict=True)
        self.nested_outcomes = [a + b + c for a, b, c in sources]
        for kind in _KINDS:
            self.child_elements[kind] += child.child_elements[kind]
            self.child_cases[kind] += child.child_cases[kind]


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
                shown = safe_name(name)
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
            self.case = _Case(f"{classname}::{case_name}" if classname else case_name)
        elif parent == "testcase" and name in _KINDS and self.case is not None:
            self._case_child(self.case, name, attrs)

    def _case_child(self, case: _Case, name: str, attrs: dict[str, str]) -> None:
        """Record a failure, error or skipped child of the open test case."""
        self.suites[-1].child_elements[name] += 1
        case.kinds.add(name)
        rank, reason = FAILED, ""
        if name == "skipped":
            xfail = attrs.get("type") == "pytest.xfail"
            rank = XFAILED if xfail else SKIPPED
            reason = attrs.get("message", "")[:MAX_TEXT_CHARS] if xfail else ""
        if rank > case.rank:
            case.rank, case.reason = rank, reason

    def end(self, name: str) -> None:
        """Handle an element end."""
        self.stack.pop()
        if name == "testcase" and self.case is not None:
            self.suites[-1].add_case(self.case)
            self.case = None
        elif name in _SUITES:
            suite = self.suites.pop()
            tests = suite.close()
            for case in tests:
                if case.rank == XFAILED:
                    self.xfails.append((case.case_id, case.reason))
            if self.suites:
                self.suites[-1].absorb(suite, tests)
            else:
                holder = _Suite({})
                holder.absorb(suite, tests)
                self.result = holder.nested_outcomes


def _refuse(*_args: object) -> NoReturn:
    """Expat handler: abort on any DOCTYPE, entity declaration or reference.

    Raises:
        Unreadable: Always.
    """
    raise Unreadable(_DECLARED)


def _check_prolog(text: str) -> None:
    """Raise when the prolog holds a markup declaration (DOCTYPE, ENTITY).

    Whitespace, comments and processing instructions are skipped; the scan
    stops at the first other markup, the root element in a valid report.
    """
    pos = 0
    while True:
        while pos < len(text) and text[pos] in " \t\r\n":
            pos += 1
        if text.startswith("<?", pos):
            closer = "?>"
        elif text.startswith("<!--", pos):
            closer = "-->"
        elif text.startswith("<!", pos):
            raise Unreadable(_DECLARED)
        else:
            return
        end = text.find(closer, pos + 2)
        if end < 0:
            return  # Unterminated: expat refuses the file as not well-formed.
        pos = end + len(closer)


def check_text(raw: bytes) -> None:
    """Raise unless ``raw`` is strict UTF-8 with a prolog free of declarations."""
    nul = raw.find(b"\x00")
    if nul >= 0:
        raise Unreadable(f"not UTF-8 text (a NUL byte at byte {nul})")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Unreadable(f"not UTF-8 (byte {error.start})") from None
    text = text.removeprefix("\ufeff")
    declared = _ENCODING_DECL.match(text)
    if declared and declared.group(1).strip().lower() not in _UTF8_NAMES:
        raise Unreadable("the report declares an encoding other than UTF-8")
    _check_prolog(text)


def read_report(path: Path, budget: list[int]) -> _Reader:
    """Count one JUnit file; raise Unreadable on any problem."""
    with path.open("rb") as handle:
        raw = handle.read(MAX_FILE_BYTES + 1)
    if len(raw) > MAX_FILE_BYTES:
        raise Unreadable(f"larger than {MAX_FILE_BYTES} bytes")
    check_text(raw)
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
