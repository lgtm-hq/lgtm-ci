# SPDX-License-Identifier: MIT
"""The case-level JUnit reader, ``scripts/ci/lib/testing/junit_reader.py`` (#1686).

It counts every ``<testcase>`` of untrusted JUnit XML, lists the expected
failures with their reasons, and refuses anything it cannot read safely: a
DOCTYPE or entity, another encoding, a malformed file, a file or artifact over
a limit, deep nesting, a symbolic link, or totals that disagree with the cases.
The last tests hold it to the attribute reader ``parse_junit_xml`` on every
JUnit fixture.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
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


def test_nested_suites_are_summed_once(reader: ModuleType) -> None:
    """Suites in suites in <testsuites> are summed; every level's totals checked."""
    result = reader.leg(HOSTILE, "nested-suites.xml")
    assert_that(result["counts"]).is_equal_to(
        {"passed": 1, "failed": 1, "skipped": 1, "xfailed": 1, "total": 4},
    )
    assert_that(result["expected_failures"]).is_equal_to(
        [{"id": "pkg.b::xf", "reason": "TICKET-7"}],
    )


def test_pytest_double_fail_counts_one_test(reader: ModuleType) -> None:
    """A call failure plus teardown error (two testcases, one id) is one test."""
    result = reader.leg(HOSTILE, "double-fail.xml")
    assert_that(result["counts"]).is_equal_to(
        {"passed": 1, "failed": 1, "skipped": 0, "xfailed": 0, "total": 2},
    )


def test_only_adjacent_cases_with_one_id_are_merged(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """The same id further apart, or an empty id, is another test, not a repeat."""
    cases = (
        '<testcase classname="c" name="a"/><testcase classname="c" name="b"/>'
        '<testcase classname="c" name="a"/><testcase/><testcase><failure/></testcase>'
    )
    (tmp_path / "r.xml").write_text(_suite(cases, tests=5, failures=1))
    assert_that(reader.leg(tmp_path, "r.xml")["counts"]).is_equal_to(
        {"passed": 4, "failed": 1, "skipped": 0, "xfailed": 0, "total": 5},
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
    ("name", "why"),
    [
        ("entity-bomb.xml", "DOCTYPE or an entity"),
        ("external-entity.xml", "DOCTYPE or an entity"),
        ("parameter-entity.xml", "DOCTYPE or an entity"),
        ("doctype-after-comment.xml", "DOCTYPE or an entity"),
        ("utf16-doctype.xml", "not UTF-8"),
        ("invalid-utf8.xml", "not UTF-8"),
        ("other-encoding.xml", "encoding other than UTF-8"),
        ("truncated.xml", "not well-formed"),
        ("undeclared-entity.xml", "not well-formed"),
        ("wrong-root.xml", "is not a test suite"),
        ("case-outside-suite.xml", "outside a <testsuite>"),
        ("totals-disagree.xml", "tests=3 but the report holds 2"),
        ("failures-disagree.xml", "failures=0 but the report holds 1"),
        ("count-too-long.xml", "at most nine digits"),
    ],
)
def test_hostile_or_inconsistent_report_is_unreadable(
    reader: ModuleType,
    name: str,
    why: str,
) -> None:
    """Each hostile or inconsistent fixture gives an unreadable leg, never counts."""
    result = reader.leg(HOSTILE, name)
    assert_that(result["status"]).is_equal_to("unreadable")
    assert_that(result["reason"]).contains(why)
    assert_that(result).does_not_contain_key("counts")


@pytest.mark.parametrize(
    "name",
    ["entity-bomb.xml", "external-entity.xml", "parameter-entity.xml"],
)
def test_parser_handlers_refuse_entities_without_the_prolog_scan(
    reader: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    name: str,
) -> None:
    """With the text scan switched off, the expat handlers still stop the parse."""
    monkeypatch.setattr(reader, "_decode", lambda _raw: None)
    with pytest.raises(reader.Unreadable, match="DOCTYPE or an entity"):
        reader.read_report(HOSTILE / name, [10])


def test_oversized_file_is_unreadable(tmp_path: Path, reader: ModuleType) -> None:
    """A file one byte over the per-file limit is not parsed."""
    body = _suite(OK_CASE, tests=1)
    filler = "x" * (reader.MAX_FILE_BYTES + 1 - len(body) - len("<!---->\n"))
    big = tmp_path / "big.xml"
    big.write_text(body.replace("<testsuite ", f"<!--{filler}-->\n<testsuite ", 1))
    assert_that(big.stat().st_size).is_equal_to(reader.MAX_FILE_BYTES + 1)
    reason = f"big.xml: larger than {reader.MAX_FILE_BYTES} bytes"
    assert_that(reader.leg(tmp_path, "big.xml")).is_equal_to(
        {"status": "unreadable", "reason": reason},
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


def test_one_hundred_thousand_cases_are_unreadable(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """100,000 test cases are over the test-case limit."""
    count = 100_000
    (tmp_path / "many.xml").write_text(_suite(OK_CASE * count, tests=count))
    result = reader.leg(tmp_path, "many.xml")
    assert_that(result["status"]).is_equal_to("unreadable")
    assert_that(result["reason"]).contains(f"more than {reader.MAX_CASES} test cases")


def test_cases_at_the_limit_are_counted(tmp_path: Path, reader: ModuleType) -> None:
    """Exactly the test-case limit, split over two files, is still counted."""
    half = reader.MAX_CASES // 2
    cases = "".join(f'<testcase classname="t" name="c{i}"/>' for i in range(half))
    for name in ("a.xml", "b.xml"):
        (tmp_path / name).write_text(_suite(cases, tests=half), encoding="utf-8")
    result = reader.leg(tmp_path, "*.xml")
    assert_that(result["counts"]["passed"]).is_equal_to(2 * half)


def test_deep_nesting_is_unreadable(tmp_path: Path, reader: ModuleType) -> None:
    """Elements nested past the depth limit stop the parse."""
    depth = reader.MAX_DEPTH + 5
    body = "<testsuite>" * depth + "</testsuite>" * depth
    (tmp_path / "deep.xml").write_text(body, encoding="utf-8")
    result = reader.leg(tmp_path, "deep.xml")
    assert_that(result["reason"]).contains(f"nested deeper than {reader.MAX_DEPTH}")


def test_symbolic_link_is_refused(tmp_path: Path, reader: ModuleType) -> None:
    """A matched symbolic link (to a file anywhere) makes the artifact unreadable."""
    os.symlink(JUNIT / "pytest-mixed.xml", tmp_path / "link.xml")
    result = reader.leg(tmp_path, "*.xml")
    assert_that(result["status"]).is_equal_to("unreadable")
    assert_that(result["reason"]).contains("symbolic link")


def test_no_matching_file_is_missing(tmp_path: Path, reader: ModuleType) -> None:
    """An artifact without a matching report is reported as missing."""
    (tmp_path / "report.json").write_text("{}", encoding="utf-8")
    assert_that(reader.leg(tmp_path, "**/*.xml")["status"]).is_equal_to("missing")


@pytest.mark.parametrize("pattern", ["/etc/*.xml", "../*.xml", "a/../../b.xml", ""])
def test_glob_escaping_the_artifact_is_a_usage_error(
    tmp_path: Path,
    pattern: str,
) -> None:
    """junit-path must stay inside the artifact: an absolute or '..' glob exits 2."""
    completed = _run("leg", str(tmp_path), pattern)
    assert_that(completed.returncode).is_equal_to(2)
    assert_that(completed.stdout).is_empty()


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


def test_long_reason_is_cut_one_past_the_contract(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """A reason keeps 501 characters, so the 500-character cut adds its ellipsis."""
    case = _xfail("a", "r" * 5000)
    (tmp_path / "r.xml").write_text(_suite(case, tests=1, skipped=1))
    entry = reader.leg(tmp_path, "r.xml")["expected_failures"][0]
    assert_that(entry["reason"]).is_length(501)


#: Expected agreement with parse_junit_xml on every JUnit fixture. A fixture
#: whose suite attributes claim more tests than it lists is unreadable to the
#: case-level reader by rule; with-doctype.xml is refused for its DOCTYPE.
FIXTURE_VERDICTS = {
    "junit/attribute-order.xml": "unreadable",
    "junit/negative-passed-clamp.xml": "unreadable",
    "junit/pytest-mixed.xml": "agree",
    "junit/pytest-xfail.xml": "agree",
    # pytest writes a call failure plus a teardown error as two testcases of
    # one test; the attribute reader adds failures and errors (2 failed of
    # 3), the case reader counts the test once (1 failed of 2).
    "junit/reader/double-fail.xml": "double-fail",
    "junit/reader/nested-suites.xml": "agree",
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
    """A new JUnit fixture must be added to the agreement table."""
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
    verdict: str,
) -> None:
    """Where the case reader can count a fixture, it gives parse_junit_xml's counts."""
    path = FIXTURES / relative
    result = reader.leg(path.parent, path.name)
    if verdict == "unreadable":
        assert_that(result["status"]).is_equal_to("unreadable")
        return
    expected = _attribute_reader_counts(path)
    counts = result["counts"]
    if verdict == "double-fail":
        assert_that((expected["failed"], expected["total"])).is_equal_to((2, 3))
        assert_that((counts["failed"], counts["total"])).is_equal_to((1, 2))
        return
    for key in ("passed", "failed", "skipped", "xfailed", "total"):
        assert_that(counts[key]).described_as(key).is_equal_to(expected[key])
