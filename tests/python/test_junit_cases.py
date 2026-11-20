# SPDX-License-Identifier: MIT
"""Per-file JUnit parsing, ``scripts/ci/lib/testing/junit_cases.py`` (#1686).

The mapping of test cases to outcomes, the totals check, the narrow pytest
merge, and the two safety layers: the text check before parsing (strict
UTF-8, no NUL byte, no markup declaration in the prolog) and the expat
handlers, each shown to refuse hostile input on its own.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
HOSTILE = PROJECT_ROOT / "tests/fixtures/junit/reader"
XML_HEAD = '<?xml version="1.0" encoding="utf-8"?>\n'
OK_CASE = '<testcase classname="t" name="a"/>'
DOCTYPE_SUITE = (
    '<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]>\n'
    '<testsuite name="s" tests="1"><testcase classname="t" name="&e;"/></testsuite>\n'
)


@pytest.fixture(name="reader", scope="module")
def fixture_reader(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the reader, which loads junit_cases through its sys.path fallback."""
    return load_script("scripts/ci/lib/testing/junit_reader.py")


@pytest.fixture(name="cases", scope="module")
def fixture_cases(reader: ModuleType) -> ModuleType:
    """Return the junit_cases module the reader uses."""
    module: ModuleType = reader.junit_cases
    return module


def _counts(reader: ModuleType, directory: Path, name: str) -> dict[str, int]:
    """Return the counts of one file, failing when it is not readable."""
    result = reader.leg(directory, name)
    assert_that(result["status"]).described_as(result.get("reason")).is_equal_to("ok")
    counts: dict[str, int] = result["counts"]
    return counts


def _expect(passed: int, failed: int, total: int) -> dict[str, int]:
    """Return a counts object without skips or expected failures."""
    return {
        "passed": passed,
        "failed": failed,
        "skipped": 0,
        "xfailed": 0,
        "total": total,
    }


def test_googletest_failures_count_one_failed_test(reader: ModuleType) -> None:
    """Two <failure> elements in one test case (failures="1") are one failed test."""
    counts = _counts(reader, HOSTILE, "googletest-two-failures.xml")
    assert_that(counts).is_equal_to(_expect(passed=1, failed=1, total=2))


def test_failure_and_error_in_one_case_is_one_failed_test(reader: ModuleType) -> None:
    """A case with a <failure> and an <error> is one failed test."""
    counts = _counts(reader, HOSTILE, "failure-and-error.xml")
    assert_that(counts).is_equal_to(_expect(passed=1, failed=1, total=2))


def test_failures_attribute_counting_elements_is_accepted(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """failures may count <failure> elements instead of failed cases."""
    case = '<testcase classname="m" name="a"><failure/><failure/></testcase>'
    (tmp_path / "r.xml").write_text(_suite(case, tests=1, failures=2))
    assert_that(_counts(reader, tmp_path, "r.xml")).is_equal_to(_expect(0, 1, 1))


def test_failures_attribute_matching_neither_is_unreadable(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """failures equal to neither the failed cases nor the elements is refused."""
    case = '<testcase classname="m" name="a"><failure/><failure/></testcase>'
    (tmp_path / "r.xml").write_text(_suite(case, tests=1, failures=3))
    result = reader.leg(tmp_path, "r.xml")
    assert_that(result["reason"]).contains(
        "failures=3 but the report holds 1 test case(s) with 2 <failure> element(s)",
    )


def _suite(cases: str, **totals: int) -> str:
    """Return a one-suite JUnit document holding ``cases``."""
    attrs = "".join(f' {key}="{value}"' for key, value in totals.items())
    return f'{XML_HEAD}<testsuite name="s"{attrs}>{cases}</testsuite>\n'


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        # Real pytest 9.2 output: tests="3" counts both elements, so no merge.
        ("double-fail.xml", _expect(passed=1, failed=2, total=3)),
        # The same pair with tests="2": merged into one failed test.
        ("double-fail-merged.xml", _expect(passed=1, failed=1, total=2)),
        # Two adjacent failures with one id are two tests.
        ("repeated-failures.xml", _expect(passed=1, failed=2, total=3)),
        # Adjacent passes with one id are separate tests too.
        ("repeated-passes.xml", _expect(passed=3, failed=0, total=3)),
    ],
)
def test_only_pytest_teardown_pair_is_merged(
    reader: ModuleType,
    name: str,
    expected: dict[str, int],
) -> None:
    """Only <failure> then same-id <error>-only merges, and only if tests allows it."""
    assert_that(_counts(reader, HOSTILE, name)).is_equal_to(expected)


def test_pair_without_tests_attribute_is_merged(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """With no tests attribute, pytest's pair is one test; other repeats are not."""
    cases = (
        '<testcase classname="c" name="a"><failure/></testcase>'
        '<testcase classname="c" name="a"><error/></testcase>'
        '<testcase classname="c" name="a"><error/></testcase>'
        "<testcase/><testcase><failure/></testcase>"
    )
    (tmp_path / "r.xml").write_text(_suite(cases))
    # The pair merges; the third same-id case and the two unnamed ones do not.
    assert_that(_counts(reader, tmp_path, "r.xml")).is_equal_to(_expect(1, 3, 4))


_NESTED_PAIR = (
    '<testcase name="t"><failure/></testcase>'
    '<testcase name="t"><error/></testcase>'
    '<testcase name="p"/>'
)


def test_enclosing_total_counting_a_merged_pair_is_unreadable(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """An outer tests that counts both halves of a nested merged pair is refused.

    Accepting it would report one failure where the report declares two.
    """
    inner = f"<testsuite>{_NESTED_PAIR}</testsuite>"
    outer = f'<testsuites tests="3" failures="1" errors="1">{inner}</testsuites>'
    (tmp_path / "r.xml").write_text(f"{XML_HEAD}{outer}\n")
    result = reader.leg(tmp_path, "r.xml")
    assert_that(result["status"]).is_equal_to("unreadable")


@pytest.mark.parametrize(
    ("inner_tests", "outer_tests", "expected"),
    [
        (3, 3, _expect(passed=1, failed=2, total=3)),
        (2, 2, _expect(passed=1, failed=1, total=2)),
        (None, 2, _expect(passed=1, failed=1, total=2)),
    ],
)
def test_enclosing_total_agreeing_with_the_nested_suite_is_counted(
    tmp_path: Path,
    reader: ModuleType,
    inner_tests: int | None,
    outer_tests: int,
    expected: dict[str, int],
) -> None:
    """Outer and nested totals that read the pair the same way are accepted."""
    attr = "" if inner_tests is None else f' tests="{inner_tests}"'
    inner = f"<testsuite{attr}>{_NESTED_PAIR}</testsuite>"
    outer = f'<testsuites tests="{outer_tests}">{inner}</testsuites>'
    (tmp_path / "r.xml").write_text(f"{XML_HEAD}{outer}\n")
    assert_that(_counts(reader, tmp_path, "r.xml")).is_equal_to(expected)


@pytest.mark.parametrize(
    ("name", "why"),
    [
        ("entity-bomb.xml", "DOCTYPE or an entity"),
        ("external-entity.xml", "DOCTYPE or an entity"),
        ("parameter-entity.xml", "DOCTYPE or an entity"),
        ("doctype-after-comment.xml", "DOCTYPE or an entity"),
        ("doctype-after-element-like-comment.xml", "DOCTYPE or an entity"),
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


#: Files that are not UTF-8 text, built here: a committed copy would not be
#: valid UTF-8 and breaks tools that read the diff as text.
NOT_UTF8 = {
    "invalid UTF-8 byte": (
        XML_HEAD.encode() + b'<testsuite><testcase name="calf\xe9"/></testsuite>',
        "not UTF-8 (byte",
    ),
    "UTF-16 with a byte-order mark": (
        (XML_HEAD + DOCTYPE_SUITE).encode("utf-16"),
        "NUL byte",
    ),
    "UTF-16 LE without a byte-order mark": (
        DOCTYPE_SUITE.encode("utf-16-le"),
        "NUL byte",
    ),
    "UTF-16 BE without a byte-order mark": (
        DOCTYPE_SUITE.encode("utf-16-be"),
        "NUL byte",
    ),
    "UTF-32 without a byte-order mark": (
        DOCTYPE_SUITE.encode("utf-32-le"),
        "NUL byte",
    ),
}


@pytest.mark.parametrize("label", sorted(NOT_UTF8))
def test_text_that_is_not_utf8_is_refused_before_parsing(
    cases: ModuleType,
    label: str,
) -> None:
    """The first layer alone refuses every non-UTF-8 form, BOM or not."""
    raw, why = NOT_UTF8[label]
    with pytest.raises(cases.Unreadable, match=why.replace("(", r"\(")):
        cases.check_text(raw)


@pytest.mark.parametrize("label", sorted(NOT_UTF8))
def test_text_that_is_not_utf8_gives_an_unreadable_leg(
    tmp_path: Path,
    reader: ModuleType,
    label: str,
) -> None:
    """End to end, a non-UTF-8 report is unreadable and never counted."""
    (tmp_path / "r.xml").write_bytes(NOT_UTF8[label][0])
    assert_that(reader.leg(tmp_path, "r.xml")["status"]).is_equal_to("unreadable")


@pytest.mark.parametrize(
    "prolog",
    [
        "<!DOCTYPE t>",
        "  <!doctype t>",
        "<!-- <a --><!DOCTYPE t>",
        "<?pi <b ?><!ENTITY e 'x'>",
        "<?xml-stylesheet href='a'?>\n<!-- c -->\n<!DOCTYPE t>",
    ],
)
def test_prolog_scan_alone_refuses_declarations(cases: ModuleType, prolog: str) -> None:
    """Layer 1 skips comments and processing instructions, then finds the DOCTYPE."""
    raw = (XML_HEAD + prolog + "\n" + _suite(OK_CASE).removeprefix(XML_HEAD)).encode()
    with pytest.raises(cases.Unreadable, match="DOCTYPE or an entity"):
        cases.check_text(raw)


def test_prolog_scan_reads_past_a_byte_order_mark(cases: ModuleType) -> None:
    """A UTF-8 byte-order mark before the declaration does not hide a DOCTYPE."""
    raw = ("\ufeff" + XML_HEAD + "<!DOCTYPE t>\n").encode() + b"<testsuite/>"
    with pytest.raises(cases.Unreadable, match="DOCTYPE or an entity"):
        cases.check_text(raw)


@pytest.mark.parametrize(
    "name",
    [
        "entity-bomb.xml",
        "external-entity.xml",
        "parameter-entity.xml",
        "doctype-after-element-like-comment.xml",
    ],
)
def test_parser_handlers_refuse_entities_without_the_text_check(
    cases: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    name: str,
) -> None:
    """With layer 1 switched off, the expat handlers still stop the parse."""
    monkeypatch.setattr(cases, "check_text", lambda _raw: None)
    with pytest.raises(cases.Unreadable, match="DOCTYPE or an entity"):
        cases.read_report(HOSTILE / name, [10])


def test_oversized_file_is_unreadable(
    tmp_path: Path,
    reader: ModuleType,
    cases: ModuleType,
) -> None:
    """A file one byte over the per-file limit is not parsed."""
    body = _suite(OK_CASE, tests=1)
    filler = "x" * (cases.MAX_FILE_BYTES + 1 - len(body) - len("<!---->\n"))
    big = tmp_path / "big.xml"
    big.write_text(body.replace("<testsuite ", f"<!--{filler}-->\n<testsuite ", 1))
    assert_that(big.stat().st_size).is_equal_to(cases.MAX_FILE_BYTES + 1)
    reason = f"big.xml: larger than {cases.MAX_FILE_BYTES} bytes"
    assert_that(reader.leg(tmp_path, "big.xml")).is_equal_to(
        {"status": "unreadable", "reason": reason},
    )


def test_one_hundred_thousand_cases_are_unreadable(
    tmp_path: Path,
    reader: ModuleType,
    cases: ModuleType,
) -> None:
    """100,000 test cases are over the test-case limit."""
    count = 100_000
    (tmp_path / "many.xml").write_text(_suite(OK_CASE * count, tests=count))
    result = reader.leg(tmp_path, "many.xml")
    assert_that(result["status"]).is_equal_to("unreadable")
    assert_that(result["reason"]).contains(f"more than {cases.MAX_CASES} test cases")


def test_cases_at_the_limit_are_counted(
    tmp_path: Path,
    reader: ModuleType,
    cases: ModuleType,
) -> None:
    """Exactly the test-case limit, split over two files, is still counted."""
    half = cases.MAX_CASES // 2
    body = "".join(f'<testcase classname="t" name="c{i}"/>' for i in range(half))
    for name in ("a.xml", "b.xml"):
        (tmp_path / name).write_text(_suite(body, tests=half), encoding="utf-8")
    assert_that(_counts(reader, tmp_path, "*.xml")["passed"]).is_equal_to(2 * half)


def test_deep_nesting_is_unreadable(
    tmp_path: Path,
    reader: ModuleType,
    cases: ModuleType,
) -> None:
    """Elements nested past the depth limit stop the parse."""
    depth = cases.MAX_DEPTH + 5
    (tmp_path / "deep.xml").write_text("<testsuite>" * depth + "</testsuite>" * depth)
    result = reader.leg(tmp_path, "deep.xml")
    assert_that(result["reason"]).contains(f"nested deeper than {cases.MAX_DEPTH}")


def test_long_reason_is_cut_one_past_the_contract(
    tmp_path: Path,
    reader: ModuleType,
) -> None:
    """A reason keeps 501 characters, so the 500-character cut adds its ellipsis."""
    skipped = '<skipped type="pytest.xfail" message="' + "r" * 5000 + '"/>'
    case = f'<testcase classname="m" name="a">{skipped}</testcase>'
    (tmp_path / "r.xml").write_text(_suite(case, tests=1, skipped=1))
    entry = reader.leg(tmp_path, "r.xml")["expected_failures"][0]
    assert_that(entry["reason"]).is_length(501)
