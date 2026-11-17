# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Reading side of ``bats-durations.py`` (#1422): test names, TAP, attribution.

``bats-durations.py`` imports this module by path. Nothing here executes
test code: a test file's tests are read statically, line by line, with the
patterns bats' own preprocessor uses, and a TAP report is parsed as text.

How bats names a test (bats-core 1.14.0). ``libexec/bats-core/bats-preprocess``
matches every line of the file against ``BATS_TEST_PATTERN``
(``@test <name> {``) and ``BATS_TEST_PATTERN_COMMENT``
(``<function>() { # @test``). It takes capture group 1, strips one leading
and one trailing ``'`` or ``"`` and emits
``bats_test_function --description <name quoted with %q> ...``. In
``lib/bats-core/test_functions.bash`` ``bats_test_function`` evaluates
``printf -v test_description '%s' "<name>"``: the name is expanded as a
double-quoted string (``$``, backticks and backslash escapes are
processed), and the result becomes ``BATS_TEST_DESCRIPTION``, which
``bats-exec-test`` prints after the test number. For the comment form the
name is the function name.

Attribution checks both the count and the names: the static tests of a
shard's files, in run order, must add up to the TAP plan, and each result
line's description must match the static name at its position (see
:func:`check_names`). A shard none of whose names can be compared (each
has ``$`` or a backtick) is refused: its count alone is not trusted.
Anything else records nothing for the shard.

Every input here was written by the same job moments earlier (the test
files of its checkout, bats' report), so it is read as it is: no size or
file-type limit.
"""

from __future__ import annotations

import re
import string
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path

# The two line patterns bats-core turns into tests, copied from
# libexec/bats-core/bats-preprocess (BATS_TEST_PATTERN and
# BATS_TEST_PATTERN_COMMENT; checked against bats-core 1.14.0). Bats reads
# the file with "$(<file)" (NUL bytes dropped), strips every CR from each
# line and tests each line on its own, whatever surrounds it: an "@test"
# line inside a heredoc is rewritten too, and whether bash then registers
# it cannot be read from the file (see _heredoc_bodies). [[:blank:]] is
# space or tab. The comment form is not anchored at the start, as in bats.
_BATS_TEST_PATTERN = re.compile(rb"^[ \t]*@test[ \t]+(.*[^ \t])[ \t]+\{(.*)\Z")
_BATS_TEST_PATTERN_COMMENT = re.compile(
    rb"[ \t]*([^ \t()]+)[ \t]*\(?\)?[ \t]+\{[ \t]+#[ \t]*@test[ \t]*\Z",
)
# bats-preprocess: name="${BASH_REMATCH[1]#[\'\"]}"; name="${name%[\'\"]}".
_QUOTES = "'\""
# In a double-quoted string bash expands "$..." and backticks; an unescaped
# double quote ends the quoting, after which globs, word splitting and
# command syntax apply. Such a name cannot be predicted statically.
_UNESCAPED_QUOTE = re.compile(r'(?<!\\)(?:\\\\)*"')
# A heredoc redirection: "<<" or "<<-", optional blanks, then the word, bare
# (optionally after one backslash) or in single or double quotes. "<<<" (a
# here-string) is not one. A "<<" that is not a heredoc (an arithmetic
# shift, text in a quoted string) is ignored unless a later line happens to
# equal its word; see _heredoc_bodies.
_HEREDOC = re.compile(
    rb"(?<!<)<<(?!<)(?P<dash>-?)[ \t]*"
    rb"(?:'(?P<single>[^']*)'|\"(?P<double>[^\"]*)\"|\\?(?P<bare>[^\s;&|<>()'\"]+))",
)

_PLAN = re.compile(r"^1\.\.(?P<total>\d+)\s*$")
_RESULT = re.compile(r"^(?:ok|not ok) (?P<number>\d+)(?P<rest>(?: .*)?)$")
# bats-format-tap: "ok N name # skip" or "ok N name # skip <reason>". The
# first " # skip" is taken as the directive; nothing after it is read as a
# time.
_SKIP = re.compile(r" # skip(?: |$)")
# bats-format-tap: " # in N ms", then " # timeout after N s" on a timed-out
# failure. Only matched at the end of a line that is not a skip.
_TIMING = re.compile(r" # in (?P<ms>\d+) ms(?: # timeout after \d+ s)?\s*$")
# lib/bats-core/formatter.bash reads "ok N <name> # skip( <reason>)?" off
# bats' internal stream, where a timed test is "ok N <name> in <N>ms". A
# passing test whose name contains " # skip " therefore reaches the report
# as "ok N <head> # skip <tail> in <N>ms": it looks skipped, and its time
# hides in the apparent reason. Such a line is ambiguous and gives no value.
_LEGACY_TIMING = re.compile(r"(?:^|\s)in (?P<ms>\d+)ms\s*$")
_SKELETON_KEEP = frozenset(string.ascii_lowercase + string.digits)


class DurationsError(Exception):
    """The input cannot give durations; nothing is recorded."""


def skeleton(text: str) -> str:
    """Reduce a test name to its lower-cased ASCII letters and digits.

    Quoting, escaping, spacing and punctuation are dropped, so the two
    sides of a comparison cannot differ by quoting alone.

    Args:
        text: A static name or a TAP description.

    Returns:
        The skeleton.
    """
    return "".join(char for char in text.lower() if char in _SKELETON_KEEP)


def _static_name(raw: bytes) -> str | None:
    """Return the description bats derives from a matched name, if knowable.

    Args:
        raw: Capture group 1 of the matched line.

    Returns:
        The name with one leading and one trailing quote removed, or None
        when bash would expand it (``$``, a backtick, or an unescaped
        double quote): such a name matches any description.
    """
    name = raw.decode("utf-8", errors="replace")
    if name[:1] in _QUOTES:
        name = name[1:]
    if name[-1:] in _QUOTES:
        name = name[:-1]
    if "$" in name or "`" in name or _UNESCAPED_QUOTE.search(name):
        return None
    return name


def _is_test_line(line: bytes) -> re.Match[bytes] | None:
    """Match ``line`` against the two patterns bats turns into a test."""
    return _BATS_TEST_PATTERN.match(line) or _BATS_TEST_PATTERN_COMMENT.search(line)


def _heredoc_openers(line: bytes) -> list[tuple[bytes, bool]]:
    """Return the heredocs a line opens, in order: (delimiter, ``<<-`` form)."""
    openers = []
    for match in _HEREDOC.finditer(line):
        word = next(
            group
            for group in (match["single"], match["double"], match["bare"])
            if group is not None
        )
        openers.append((word, match["dash"] == b"-"))
    return openers


def _heredoc_bodies(lines: Sequence[bytes]) -> list[tuple[int, int]]:
    """Find the heredoc bodies of a file, conservatively.

    A heredoc opened on line *i* ends at the first later line that equals
    its delimiter (leading tabs stripped for ``<<-``); several heredocs on
    one line follow each other. A ``<<`` with no such later line is taken
    to be no heredoc at all, so ordinary code is never mistaken for one.
    Nothing else of bash is understood: a ``<<`` in a quoted string or an
    arithmetic shift counts only if a later line equals its word.

    Args:
        lines: The file's lines, CR and NUL bytes removed.

    Returns:
        ``(first, end)`` index ranges of body lines, delimiter excluded.
    """
    exact: dict[bytes, list[int]] = {}
    tabbed: dict[bytes, list[int]] = {}
    for index, line in enumerate(lines):
        exact.setdefault(line, []).append(index)
        tabbed.setdefault(line.lstrip(b"\t"), []).append(index)
    bodies: list[tuple[int, int]] = []
    index = 0
    while index < len(lines):
        start = index + 1
        for word, dash in _heredoc_openers(lines[index]):
            ends = (tabbed if dash else exact).get(word, [])
            end = next((n for n in ends if n >= start), None)
            if end is None:
                continue
            bodies.append((start, end))
            start = end + 1
        index = start
    return bodies


def read_tests(path: Path) -> list[str | None]:
    """Read a file's test names, in file order, the way bats preprocesses it.

    Nothing in the file is executed. What bats registers can differ: an
    ``@test`` line in code that never runs is read here but never
    registered, and a test registered at run time (by a loaded helper
    calling ``bats_test_function``, or generated in a loop) is not read.
    The name check of :func:`check_names` then refuses the shard. A file
    whose own text names ``bats_test_function``, or that has a test
    definition inside heredoc text (:func:`_heredoc_bodies`), is refused
    outright: whether bash registers such a test cannot be read.

    Args:
        path: The test file.

    Returns:
        One entry per line bats would turn into a test: its name, or None
        when the name cannot be predicted (:func:`_static_name`).

    Raises:
        DurationsError: The file cannot be read, registers tests at run
            time, or has a test definition in a heredoc.
    """
    try:
        data = path.read_bytes()
    except OSError as error:
        raise DurationsError(f"cannot read test file {path}: {error}") from error
    lines = [raw.replace(b"\r", b"").replace(b"\0", b"") for raw in data.split(b"\n")]
    if any(b"bats_test_function" in line for line in lines):
        raise DurationsError(f"{path} registers tests at run time (bats_test_function)")
    for first, end in _heredoc_bodies(lines):
        for index in range(first, end):
            if _is_test_line(lines[index]):
                raise DurationsError(
                    f"{path}:{index + 1}: a test definition inside heredoc text "
                    "(bats may or may not register it)",
                )
    names: list[str | None] = []
    for line in lines:
        if match := _is_test_line(line):
            names.append(_static_name(match.group(1)))
    return names


@dataclass
class TapTimings:
    """Timed and skipped test numbers of one TAP stream.

    Attributes:
        plan: N of the ``1..N`` line, or None without one.
        timed_ms: Test number to its time (ms).
        skipped: Test numbers with a ``# skip`` result line.
        ambiguous: Test numbers whose line looks skipped but may hide a
            time (:data:`_LEGACY_TIMING`); they count as neither.
        descriptions: Test number to the descriptions its result line can
            be read as (more than one when the line is ambiguous).
    """

    plan: int | None = None
    timed_ms: dict[int, int] = field(default_factory=dict)
    skipped: set[int] = field(default_factory=set)
    ambiguous: set[int] = field(default_factory=set)
    descriptions: dict[int, tuple[str, ...]] = field(default_factory=dict)


def _skip_readings(rest: str) -> tuple[str, ...]:
    """Return the names a skip line can carry: the text before each ``# skip``."""
    return tuple(rest[: match.start()] for match in _SKIP.finditer(rest))


def parse_tap(text: str) -> TapTimings:
    """Read the plan, per-test times and descriptions of a ``--timing`` report.

    Args:
        text: TAP written by bats' ``tap`` report formatter with ``--timing``.

    Returns:
        The parsed timings. Lines that are neither timed nor skipped
        (diagnostics, the untimed ``setup_file failed`` and
        ``teardown_file failed`` lines) are ignored.

    Raises:
        DurationsError: More than one plan line, or a test number with two
            timed, skipped or ambiguous results: two reports in one file.
    """
    timings = TapTimings()
    for line in text.splitlines():
        if plan := _PLAN.match(line):
            if timings.plan is not None:
                raise DurationsError("the TAP has more than one plan line")
            timings.plan = int(plan.group("total"))
            continue
        result = _RESULT.match(line)
        if not result:
            continue
        number = int(result.group("number"))
        rest = result.group("rest")
        skip = _SKIP.search(rest)
        timing = None if skip else _TIMING.search(rest)
        if skip is None and timing is None:
            continue
        if number in timings.descriptions:
            raise DurationsError(f"test {number} has more than one result")
        if skip is None:
            if timing is not None:
                timings.timed_ms[number] = int(timing.group("ms"))
                timings.descriptions[number] = (rest[: timing.start()],)
        elif legacy := _LEGACY_TIMING.search(rest[skip.end() :]):
            timings.ambiguous.add(number)
            whole = rest[: skip.end() + legacy.start()]
            timings.descriptions[number] = (*_skip_readings(rest), whole)
        else:
            timings.skipped.add(number)
            timings.descriptions[number] = _skip_readings(rest)
    return timings


def check_names(
    files: Sequence[str],
    tests: Mapping[str, Sequence[str | None]],
    timings: TapTimings,
) -> None:
    """Check each result line's description against the static name.

    The static names of all files, in run order, give the expected name of
    every test number. A number with a timed, skipped or ambiguous result
    line must match: the skeletons (:func:`skeleton`) of the static name
    and of one reading of the description are equal. A static name bash
    would expand (None) matches anything. A number without such a line
    (a failed ``setup_file``, a cut-short run) is not compared; its file
    has no value anyway.

    Args:
        files: Files in the order bats ran them.
        tests: Static names of each file (:func:`read_tests`).
        timings: Parsed TAP of the run.

    Raises:
        DurationsError: At the first position that differs, naming it, the
            file expected there and both names.
    """
    expected = [(path, name) for path in files for name in tests[path]]
    for number, (path, name) in enumerate(expected, start=1):
        readings = timings.descriptions.get(number)
        if name is None or readings is None:
            continue
        want = skeleton(name)
        if not any(skeleton(reading) == want for reading in readings):
            raise DurationsError(
                f"test {number} should be {name!r} of {path}, the report says "
                f"{readings[-1].strip()!r} (a test bats registers differently)",
            )


def attribute(
    files: Sequence[str],
    tests: Mapping[str, Sequence[str | None]],
    timings: TapTimings,
) -> tuple[dict[str, float], list[str]]:
    """Split the run's test times by file.

    Args:
        files: Files in the order bats ran them.
        tests: Static names of each file (:func:`read_tests`).
        timings: Parsed TAP of the run.

    Returns:
        Seconds per file with a complete set of results, and the files
        without one (in run order).

    Raises:
        DurationsError: No plan, a file without names, counts that do not
            add up to the plan, no name that can be checked, or a name that
            differs from the report. On a count mismatch the name check runs
            first, so a differing name (which names its file) is reported in
            place of the totals.
    """
    if timings.plan is None:
        raise DurationsError("the TAP has no 1..N plan")
    absent = [path for path in files if path not in tests]
    if absent:
        raise DurationsError(f"no test count for {', '.join(absent)}")
    counted = sum(len(tests[path]) for path in files)
    if counted != timings.plan:
        # A differing name names the file to fix; the totals do not.
        check_names(files, tests, timings)
        raise DurationsError(
            f"test counts add up to {counted}, the TAP plan says {timings.plan}",
        )
    names = [name for path in files for name in tests[path]]
    if names and all(name is None for name in names):
        # Every name has "$" or a backtick: only the count would be checked,
        # and two counting errors can cancel out. One such name among
        # others is fine; the names around it pin the positions.
        raise DurationsError(
            "no test name of this shard can be compared with the report "
            "(each contains $ or a backtick); the count alone is not trusted",
        )
    untimed = timings.plan and not timings.timed_ms
    if untimed and len(timings.skipped) < timings.plan:
        raise DurationsError("no result line has a time (bats ran without --timing)")
    check_names(files, tests, timings)
    durations: dict[str, float] = {}
    missing: list[str] = []
    first = 1
    for path in files:
        numbers = range(first, first + len(tests[path]))
        first += len(tests[path])
        if all(n in timings.timed_ms or n in timings.skipped for n in numbers):
            total_ms = sum(timings.timed_ms.get(n, 0) for n in numbers)
            durations[path] = round(total_ms / 1000, 3)
        else:
            missing.append(path)
    return durations, missing
