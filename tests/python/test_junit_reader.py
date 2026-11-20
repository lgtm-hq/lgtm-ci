# SPDX-License-Identifier: MIT
"""The JUnit artifact reader, ``scripts/ci/lib/testing/junit_reader.py`` (#1686).

It walks one downloaded artifact within an entry and a file limit, matches
``junit-path``, refuses symbolic links and globs that leave the artifact, sums
the reports, and caps the expected failures it emits. The last tests hold its
counts to the attribute reader ``parse_junit_xml`` on every JUnit fixture.
Per-file parsing and XML safety are tested in ``test_junit_cases.py``.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
READER_PATH = "scripts/ci/lib/testing/junit_reader.py"
FIXTURES = PROJECT_ROOT / "tests/fixtures"
JUNIT = FIXTURES / "junit"
HOSTILE = JUNIT / "reader"
#: The reason of the hostile pytest fixture, as pytest wrote it.
HOSTILE_REASON = " ".join(
    [
        "TICKET-12 @org/team #1 <img src=x> [x](javascript:y)",
        "<!-- lgtm-ci:history:start -->",
    ],
)
XML_HEAD = '<?xml version="1.0" encoding="utf-8"?>\n'
OK_CASE = '<testcase classname="t" name="a"/>'


@pytest.fixture(name="reader", scope="module")
def fixture_reader(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the reader module by path, as python3 -I runs it."""
    return load_script(READER_PATH)


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    """Run the reader the way the workflow does: python3 -I."""
    return subprocess.run(
        [sys.executable, "-I", str(PROJECT_ROOT / READER_PATH), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _suite(cases: str, **totals: int) -> str:
    """Return a one-suite JUnit document holding ``cases``."""
    attrs = "".join(f' {key}="{value}"' for key, value in totals.items())
    return f'{XML_HEAD}<testsuite name="s"{attrs}>{cases}</testsuite>\n'


def _xfail(name: str, message: str) -> str:
    """Return a pytest expected-failure test case in class ``m``."""
    skipped = f'<skipped type="pytest.xfail" message="{message}"/>'
    return f'<testcase classname="m" name="{name}">{skipped}</testcase>'


def test_pytest_report_maps_every_outcome(reader: ModuleType) -> None:
    """Real pytest output: passed, failed, error, skipped, xfail, both xpasses."""
    result = reader.leg(JUNIT, "pytest-mixed.xml")
    assert_that(result["status"]).is_equal_to("ok")
    # The loose xpass is a plain passing testcase in JUnit; the strict one fails.
    assert_that(result["counts"]).is_equal_to(
        {"passed": 2, "failed": 3, "skipped": 1, "xfailed": 3, "total": 9},
    )
    assert_that(result["expected_failures"]).is_equal_to(
        [
            {"id": "pkg.test_x::test_xfail_raises", "reason": HOSTILE_REASON},
            {"id": "pkg.test_x.TestC::test_p[1]", "reason": "param reason"},
            {"id": "pkg.test_x.TestC::test_p[2]", "reason": "param reason"},
        ],
    )
    assert_that(result["expected_failures_omitted"]).is_equal_to(0)


def test_nested_suites_are_summed_once(reader: ModuleType) -> None:
    """Suites in suites in <testsuites> are summed; every level's totals checked."""
    result = reader.leg(HOSTILE, "nested-suites.xml")
    assert_that(result["counts"]).is_equal_to(
        {"passed": 1, "failed": 1, "skipped": 1, "xfailed": 1, "total": 4},
    )
    assert_that(result["expected_failures"]).is_equal_to(
        [{"id": "pkg.b::xf", "reason": "TICKET-7"}],
    )


def test_several_files_in_one_artifact_are_summed(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """The default glob finds reports at any depth and adds them up."""
    (tmp_path / "a").mkdir()
    mixed = (JUNIT / "pytest-mixed.xml").read_bytes()
    (tmp_path / "a" / "one.xml").write_bytes(mixed)
    (tmp_path / "two.xml").write_bytes((JUNIT / "pytest-xfail.xml").read_bytes())
    (tmp_path / "notes.txt").write_text("not a report", encoding="utf-8")
    result = reader.leg(tmp_path, "**/*.xml")
    assert_that(result["files"]).is_equal_to(2)
    assert_that(result["counts"]).is_equal_to(
        {"passed": 4, "failed": 4, "skipped": 1, "xfailed": 7, "total": 16},
    )
    assert_that(result["expected_failures"]).is_length(7)


@pytest.mark.parametrize(
    ("pattern", "expected"),
    [
        ("**/*.xml", ["a/b/deep.xml", "a/mid.xml", "top.xml"]),
        ("*.xml", ["top.xml"]),
        ("a/*.xml", ["a/mid.xml"]),
        ("a/**", ["a/b/deep.xml", "a/mid.xml", "a/notes.txt"]),
        ("**/deep.xml", ["a/b/deep.xml"]),
        ("[at]*/mid.xml", ["a/mid.xml"]),
        ("t?p.xml", ["top.xml"]),
    ],
)
def test_glob_matches_like_a_path_glob(
    tmp_path: Path,
    reader: ModuleType,
    pattern: str,
    expected: list[str],
) -> None:
    """``*``, ``?`` and ``[...]`` stay within a name; ``**`` spans directories."""
    for relative in ("top.xml", "a/mid.xml", "a/notes.txt", "a/b/deep.xml"):
        path = tmp_path / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x", encoding="utf-8")
    files, _directory = reader.matches(tmp_path, pattern)
    listed = [str(path.relative_to(tmp_path)) for path in files]
    assert_that(listed).is_equal_to(expected)


@pytest.mark.parametrize(
    ("pattern", "relative", "expected"),
    [
        ("**", "x/y", True),
        ("a/**", "a", False),
        ("**/deep.xml", "deep.xml", True),
        ("a/**/b/**/c.xml", "a/b/c.xml", True),
        ("a/**/b/**/c.xml", "a/x/b/y/z/c.xml", True),
        ("a/**/b/**/c.xml", "a/c.xml", False),
        ("**/**/x.xml", "x.xml", True),
        ("*.xml", "top.XML", False),
        ("[!]].xml", "a.xml", True),
        ("*-*.xml", "a-b.xml", True),
    ],
)
def test_glob_matcher_cases(
    reader: ModuleType,
    pattern: str,
    relative: str,
    expected: bool,
) -> None:
    """``**`` matches zero or more directories; a trailing ``**`` needs a name."""
    assert_that(reader.glob_matcher(pattern)(relative)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("pattern", "name"),
    [
        ("*-*-*-*-*.xml", "-" * 250),
        ("*****.xml", "x" * 250),
        ("**/*-*-*-*.xml", "-" * 250),
        ("*a*a*a*a*a*a*a*b", "a" * 400),
    ],
)
def test_glob_matcher_time_does_not_grow_with_stars(
    reader: ModuleType,
    pattern: str,
    name: str,
) -> None:
    """A hostile file name cannot make matching slow, whatever the pattern.

    These took seconds per name with a backtracking pattern; 2 000 names
    must finish well inside a second.
    """
    matched = reader.glob_matcher(pattern)
    started = time.monotonic()
    for index in range(2000):
        matched(f"{name}{index}")
    assert_that(time.monotonic() - started).is_less_than(1.0)


def test_glob_longer_than_the_limit_is_a_bad_path(reader: ModuleType) -> None:
    """An oversized junit-path is refused before any file is looked at."""
    pattern = "x" * (reader.MAX_PATTERN_CHARS + 1)
    with pytest.raises(reader.BadPath):
        reader.glob_matcher(pattern)


def test_unnamed_expected_failures_never_push_out_a_named_one(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """Cases without an id are counted as omitted; the cap applies to named ones."""
    unnamed = reader.MAX_LISTED + 5
    skipped = '<skipped type="pytest.xfail" message="known"/>'
    cases = "".join(f"<testcase>{skipped}</testcase>" for _ in range(unnamed))
    cases += f'<testcase classname="pkg.mod" name="named">{skipped}</testcase>'
    total = unnamed + 1
    suite = f'<testsuite tests="{total}" failures="0" errors="0" skipped="{total}">'
    (tmp_path / "report.xml").write_text(
        f"{suite}{cases}</testsuite>",
        encoding="utf-8",
    )
    result = reader.leg(tmp_path, "*.xml")
    assert_that(result["status"]).is_equal_to("ok")
    assert_that(result["counts"]["xfailed"]).is_equal_to(total)
    listed = result["expected_failures"]
    assert_that([entry["id"] for entry in listed]).is_equal_to(["pkg.mod::named"])
    assert_that(result["expected_failures_omitted"]).is_equal_to(unnamed)


@pytest.mark.parametrize("target", ["file", "directory"])
def test_symbolic_link_is_refused(
    tmp_path: Path,
    reader: ModuleType,
    target: str,
) -> None:
    """A symbolic link anywhere in the artifact, to a file or a directory, fails."""
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "r.xml").write_bytes((JUNIT / "pytest-mixed.xml").read_bytes())
    artifact = tmp_path / "artifact"
    artifact.mkdir()
    source = outside / "r.xml" if target == "file" else outside
    os.symlink(source, artifact / ("link.xml" if target == "file" else "reports"))
    result = reader.leg(artifact, "**/*.xml")
    assert_that(result["status"]).is_equal_to("unreadable")
    assert_that(result["reason"]).ends_with("is a symbolic link")


def test_no_matching_file_is_missing(tmp_path: Path, reader: ModuleType) -> None:
    """An artifact without a matching report is reported as missing."""
    (tmp_path / "report.json").write_text("{}", encoding="utf-8")
    assert_that(reader.leg(tmp_path, "**/*.xml")).is_equal_to(
        {"status": "missing", "reason": "junit-path matches no file"},
    )


def test_glob_matching_only_a_directory_says_so(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """junit-path naming a directory is missing, with the reason saying why."""
    (tmp_path / "reports").mkdir()
    report = (JUNIT / "pytest-xfail.xml").read_bytes()
    (tmp_path / "reports" / "r.xml").write_bytes(report)
    assert_that(reader.leg(tmp_path, "reports")).is_equal_to(
        {"status": "missing", "reason": "junit-path matches only directories"},
    )


@pytest.mark.parametrize(
    "pattern",
    ["/etc/*.xml", "../*.xml", "a/../../b.xml", "", ".", "./x.xml", "a//b.xml", "a/"],
)
def test_bad_glob_is_a_clear_input_error(tmp_path: Path, pattern: str) -> None:
    """A glob that is absolute, empty or has '.', '..' or empty parts is bad-path."""
    completed = _run("leg", str(tmp_path), pattern)
    assert_that(completed.returncode).is_equal_to(0)
    result = json.loads(completed.stdout)
    assert_that(result["status"]).is_equal_to("bad-path")
    assert_that(result["reason"]).starts_with("junit-path must be a relative glob")


def test_walk_stops_past_the_file_limit(
    tmp_path: Path,
    reader: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """More matching files than the limit stop the walk, before any is parsed."""
    monkeypatch.setattr(reader, "MAX_FILES", 5)
    for index in range(12):
        (tmp_path / f"r{index:02d}.xml").write_text("not even XML")
    result = reader.leg(tmp_path, "*.xml")
    assert_that(result).is_equal_to(
        {"status": "unreadable", "reason": "more than 5 report files"},
    )


def test_walk_stops_past_the_entry_limit(
    tmp_path: Path,
    reader: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A generated tree with more entries than the limit is refused, files or not."""
    monkeypatch.setattr(reader, "MAX_ENTRIES", 50)
    for outer in range(6):
        directory = tmp_path / f"d{outer}"
        directory.mkdir()
        for inner in range(10):
            (directory / f"n{inner}.txt").write_text("")
    (tmp_path / "r.xml").write_text(_suite(OK_CASE, tests=1))
    result = reader.leg(tmp_path, "r.xml")
    assert_that(result).is_equal_to(
        {"status": "unreadable", "reason": "the artifact holds more than 50 entries"},
    )


def test_artifact_over_the_total_size_is_unreadable(
    tmp_path: Path,
    reader: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The files of one artifact together stay under the per-artifact limit."""
    monkeypatch.setattr(reader, "MAX_LEG_BYTES", 2000)
    mixed = (JUNIT / "pytest-mixed.xml").read_bytes()
    for index in range(3):
        (tmp_path / f"r{index}.xml").write_bytes(mixed)
    result = reader.leg(tmp_path, "*.xml")
    assert_that(result["status"]).is_equal_to("unreadable")
    assert_that(result["reason"]).contains("exceed 2000 bytes together")


def test_emitted_expected_failures_are_capped(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """Past MAX_LISTED, expected failures are only counted, in omitted."""
    count = reader.MAX_LISTED + 25
    cases = "".join(_xfail(f"t{i}", "r") for i in range(count))
    (tmp_path / "r.xml").write_text(_suite(cases, tests=count, skipped=count))
    result = reader.leg(tmp_path, "r.xml")
    assert_that(result["counts"]["xfailed"]).is_equal_to(count)
    assert_that(result["expected_failures"]).is_length(reader.MAX_LISTED)
    assert_that(result["expected_failures_omitted"]).is_equal_to(25)


def test_log_reason_cannot_start_a_workflow_command(tmp_path: Path) -> None:
    """A file name with a newline and '::' reaches the reason as safe characters."""
    (tmp_path / "x\n::error::forged.xml").write_text("<testsuite><bad")
    completed = _run("leg", str(tmp_path), "*.xml")
    reason = json.loads(completed.stdout)["reason"]
    assert_that(reason).does_not_contain("\n")
    assert_that(reason).starts_with("x?::error::forged.xml")


def test_cli_prints_one_json_document(tmp_path: Path) -> None:
    """python3 -I runs the reader standalone and prints its result as JSON."""
    (tmp_path / "r.xml").write_bytes((JUNIT / "pytest-mixed.xml").read_bytes())
    completed = _run("leg", str(tmp_path), "*.xml")
    assert_that(completed.returncode).is_equal_to(0)
    assert_that(json.loads(completed.stdout)["counts"]["total"]).is_equal_to(9)


def test_cli_usage_error_exits_two() -> None:
    """A wrong command line is a usage error with exit status 2."""
    completed = _run("leg", "only-one-argument")
    assert_that(completed.returncode).is_equal_to(2)
    assert_that(completed.stderr).contains("usage:")


def test_reasons_by_id_drop_ambiguous_ids(tmp_path: Path, reader: ModuleType) -> None:
    """The reasons command maps ids to reasons, leaving out an id with two."""
    first = _xfail("a", "one") + _xfail("b", "kept")
    second = _xfail("a", "two")
    (tmp_path / "r.xml").write_text(
        f'<testsuites><testsuite name="x">{first}</testsuite>'
        f'<testsuite name="y">{second}</testsuite></testsuites>',
        encoding="utf-8",
    )
    assert_that(reader.reasons(tmp_path / "r.xml")).is_equal_to(
        {"status": "ok", "reasons": {"m::b": "kept"}},
    )


#: Expected agreement with parse_junit_xml on every JUnit fixture: "agree",
#: "unreadable" (suite attributes that claim more tests than the file lists,
#: or a DOCTYPE), or the case reader's (failed, total) where the two differ
#: on purpose: the attribute reader adds failures and errors, the case reader
#: counts each failed test once.
FIXTURE_VERDICTS: dict[str, str | tuple[int, int]] = {
    "junit/attribute-order.xml": "unreadable",
    "junit/negative-passed-clamp.xml": "unreadable",
    "junit/pytest-mixed.xml": "agree",
    "junit/pytest-xfail.xml": "agree",
    "junit/reader/double-fail.xml": "agree",
    "junit/reader/double-fail-merged.xml": (1, 2),
    "junit/reader/failure-and-error.xml": (1, 2),
    "junit/reader/googletest-two-failures.xml": "agree",
    "junit/reader/nested-suites.xml": "agree",
    "junit/reader/repeated-failures.xml": "agree",
    "junit/single-suite-all-passing.xml": "unreadable",
    "junit/single-suite-missing-optional.xml": "unreadable",
    "junit/single-suite-mixed.xml": "unreadable",
    "junit/testsuites-aggregate-children.xml": "unreadable",
    "junit/testsuites-mixed-root-child.xml": "unreadable",
    "junit/testsuites-summary.xml": "unreadable",
    "junit/with-comments.xml": "unreadable",
    "junit/with-doctype.xml": "unreadable",
    "playwright/reports/junit-mixed.xml": "agree",
    "rust/junit-one-test.xml": "unreadable",
    "rust/junit-skipped-pass-rate.xml": "unreadable",
    "rust/junit-two-tests.xml": "unreadable",
}


def _attribute_reader_counts(path: Path) -> dict[str, int]:
    """Return junit_results_v1's counts (the attribute reader) for one file."""
    script = (
        "source scripts/ci/lib/testing/parse.sh"
        ' && RESULTS_SOURCE_VERSION=t junit_results_v1 "$1" | jq -c .counts'
    )
    completed = subprocess.run(
        ["bash", "-c", script, "bash", str(path)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    counts: dict[str, int] = json.loads(completed.stdout)
    counts.setdefault("xfailed", 0)
    return counts


def test_every_junit_fixture_has_a_verdict() -> None:
    """A new JUnit fixture outside the hostile set must be added to the table."""
    found = {
        str(path.relative_to(FIXTURES))
        for path in FIXTURES.rglob("*.xml")
        if b"<testsuite" in path.read_bytes() and path.parent != HOSTILE
    }
    listed = {key for key in FIXTURE_VERDICTS if not key.startswith("junit/reader/")}
    assert_that(found).is_equal_to(listed)


@pytest.mark.parametrize(("relative", "verdict"), sorted(FIXTURE_VERDICTS.items()))
def test_case_reader_agrees_with_attribute_reader(
    reader: ModuleType,
    relative: str,
    verdict: str | tuple[int, int],
) -> None:
    """Where the case reader can count a fixture, it gives parse_junit_xml's counts."""
    path = FIXTURES / relative
    result = reader.leg(path.parent, path.name)
    if verdict == "unreadable":
        assert_that(result["status"]).is_equal_to("unreadable")
        return
    expected = _attribute_reader_counts(path)
    counts = result["counts"]
    if isinstance(verdict, tuple):
        assert_that((counts["failed"], counts["total"])).is_equal_to(verdict)
        assert_that(expected["failed"]).is_greater_than(counts["failed"])
        return
    for key in ("passed", "failed", "skipped", "xfailed", "total"):
        assert_that(counts[key]).described_as(key).is_equal_to(expected[key])
