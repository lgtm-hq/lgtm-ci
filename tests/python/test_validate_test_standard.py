# SPDX-License-Identifier: MIT
"""Tests for the test-standard check (#1625).

``scripts/ci/quality/validate_test_standard.py`` reports bare ``assert``
statements, ``unittest.TestCase`` classes and test functions without a
docstring under ``tests/``, against a baseline that may only shrink. The CI
job ``🧪 Test Standard`` runs it on the repository; so does
:func:`test_repository_matches_baseline`.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/quality/validate_test_standard.py"
TEST_A = "tests/python/test_a.py"
BARE = "[bare-assert] bare assert; use assertpy (assert_that)"
NO_DOC = "has no docstring saying what it proves"


def source(*lines: str) -> str:
    """Join source lines into a file's text, with a final newline."""
    return "\n".join(lines) + "\n"


CLEAN = source(
    '"""A clean test file."""',
    "",
    "",
    "def test_ok() -> None:",
    '    """Prove nothing."""',
)
ONE_ASSERT = source(
    "def test_a():",
    '    """Doc."""',
    "    assert 1",
)


@pytest.fixture(name="check", scope="module")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return an empty repository root with a ``tests/`` directory."""
    (tmp_path / "tests").mkdir()
    return tmp_path


def write(repo: Path, relative: str, text: str) -> None:
    """Write one file into the repository, creating its directories."""
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def rendered(check: ModuleType, repo: Path) -> list[str]:
    """Return every offence in the repository as ``file:line: [rule] what``."""
    offences, errors = check.check(repo)
    assert_that(errors).is_empty()
    return [offence.render() for offence in offences]


def run(check: ModuleType, repo: Path, baseline: str, *flags: str) -> int:
    """Run ``main`` on the repository with a baseline file of the given text."""
    path = repo / "baseline.txt"
    path.write_text(baseline, encoding="utf-8")
    argv = ["--repo-root", str(repo), "--baseline", str(path), *flags]
    return int(check.main(argv))


def test_bare_assert_is_reported_with_file_and_line(
    check: ModuleType,
    repo: Path,
) -> None:
    """Every assert statement, nested or not, is named by file and line."""
    text = source(
        "def test_a() -> None:",
        '    """Doc."""',
        "    assert 1",
        "",
        "",
        "def helper():",
        "    assert 2",
    )
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_equal_to(
        [f"{TEST_A}:3: {BARE}", f"{TEST_A}:7: {BARE}"],
    )


@pytest.mark.parametrize(
    "base",
    [
        pytest.param("unittest.TestCase", id="attribute"),
        pytest.param("TestCase", id="imported-name"),
        pytest.param("unittest.IsolatedAsyncioTestCase", id="async-case"),
    ],
)
def test_testcase_class_is_reported(
    check: ModuleType,
    repo: Path,
    base: str,
) -> None:
    """A class deriving directly from a unittest case class is reported."""
    write(repo, TEST_A, source("import unittest", f"class Cases({base}):", "    pass"))
    assert_that(rendered(check, repo)).is_equal_to(
        [
            f"{TEST_A}:2: [unittest-class] class Cases is a unittest.TestCase; "
            "use pytest functions",
        ],
    )


def test_indirect_testcase_subclass_across_files_is_reported(
    check: ModuleType,
    repo: Path,
) -> None:
    """A case class derived from a shared base in another file counts too."""
    base = source("import unittest", "class Base(unittest.TestCase):", "    pass")
    write(repo, "tests/helpers/support.py", base)
    cases = source("from support import Base", "class Cases(Base):", "    pass")
    write(repo, "tests/helpers/cases.py", cases)
    write(repo, "tests/helpers/other.py", source("class Plain(object):", "    pass"))
    files = [line.split(":", 1)[0] for line in rendered(check, repo)]
    assert_that(files).is_equal_to(
        ["tests/helpers/cases.py", "tests/helpers/support.py"],
    )


def test_missing_docstring_is_reported_only_for_tests(
    check: ModuleType,
    repo: Path,
) -> None:
    """Module and class ``test*`` functions need a docstring; others do not."""
    text = source(
        "def test_bare():",
        "    def test_nested():",
        "        pass",
        'def test_empty():\n    """ """',
        "def helper():",
        "    pass",
        "class TestGroup:",
        "    async def test_method(self):",
        "        pass",
    )
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_equal_to(
        [
            f"{TEST_A}:1: [missing-docstring] test_bare {NO_DOC}",
            f"{TEST_A}:4: [missing-docstring] test_empty {NO_DOC}",
            f"{TEST_A}:9: [missing-docstring] test_method {NO_DOC}",
        ],
    )


def test_fixture_projects_are_not_scanned(check: ModuleType, repo: Path) -> None:
    """Files under ``tests/fixtures`` are data for other tests, not test code."""
    fixture = source("def test_x():", "    assert 1")
    write(repo, "tests/fixtures/project/test_x.py", fixture)
    write(repo, "tests/python/test_ok.py", CLEAN)
    assert_that(rendered(check, repo)).is_empty()


def test_unparsable_file_is_an_error(check: ModuleType, repo: Path) -> None:
    """A test file that does not parse fails the check with its line."""
    write(repo, "tests/python/test_bad.py", "def broken(:\n")
    _, errors = check.check(repo)
    assert_that(errors).is_length(1)
    assert_that(errors[0]).starts_with("tests/python/test_bad.py:1: does not parse")


def test_file_matching_its_baseline_passes(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Offences within the baseline pass and print the OK line."""
    write(repo, TEST_A, ONE_ASSERT)
    baseline = f"# comment\n{TEST_A} bare-assert 1  # trailing\n"
    assert_that(run(check, repo, baseline)).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains("OK: test code matches")


def test_file_worse_than_baseline_fails_naming_every_offence(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A file over its entry fails and lists each offence of that rule."""
    write(repo, TEST_A, ONE_ASSERT + "    assert 2\n")
    status = run(check, repo, f"{TEST_A} bare-assert 1\n")
    out = capsys.readouterr().out
    assert_that(status).is_equal_to(1)
    assert_that(out).contains(f"{TEST_A}: 2 bare-assert offences, baseline allows 1:")
    assert_that(out).contains(f"{TEST_A}:3: [bare-assert]")
    assert_that(out).contains(f"{TEST_A}:4: [bare-assert]")


def test_new_offending_file_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A file with offences and no baseline entry fails."""
    write(repo, "tests/python/test_new.py", source("def test_new():", "    pass"))
    assert_that(run(check, repo, "")).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "tests/python/test_new.py: 1 missing-docstring offences, baseline allows 0:",
    )


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        pytest.param(ONE_ASSERT, "now 1; lower it to 1", id="fewer-offences"),
        pytest.param(CLEAN, "now 0; remove the entry", id="clean-file"),
        pytest.param(None, "now 0; remove the entry", id="deleted-file"),
    ],
)
def test_stale_baseline_entry_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    text: str | None,
    expected: str,
) -> None:
    """An entry above the offences found must be lowered or removed."""
    if text is not None:
        write(repo, TEST_A, text)
    assert_that(run(check, repo, f"{TEST_A} bare-assert 2\n")).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        f"{TEST_A}: stale baseline entry: bare-assert 2, {expected}",
    )


@pytest.mark.parametrize(
    "line",
    [
        pytest.param(f"{TEST_A} bare-assert", id="missing-count"),
        pytest.param(f"{TEST_A} no-such-rule 1", id="unknown-rule"),
        pytest.param(f"{TEST_A} bare-assert 0", id="zero-count"),
        pytest.param(f"{TEST_A} bare-assert many", id="non-numeric-count"),
    ],
)
def test_malformed_baseline_line_is_an_error(check: ModuleType, line: str) -> None:
    """A baseline line is ``file rule count`` with a known rule and a count > 0."""
    allowed, errors = check.parse_baseline(f"{line}\n")
    assert_that(allowed).is_empty()
    assert_that(errors).is_length(1)
    assert_that(errors[0]).starts_with("baseline line 1: expected")


def test_duplicate_baseline_entry_is_an_error(check: ModuleType) -> None:
    """The same file and rule may appear only once in the baseline."""
    text = "tests/a.py bare-assert 1\ntests/a.py bare-assert 2\n"
    allowed, errors = check.parse_baseline(text)
    assert_that(allowed).is_length(1)
    assert_that(errors).is_equal_to(
        ["baseline line 2: duplicate entry for tests/a.py bare-assert"],
    )


def test_summary_and_all_print_totals_and_offences(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``--summary`` prints totals per rule; ``--all`` prints every offence."""
    write(repo, TEST_A, ONE_ASSERT)
    baseline = f"{TEST_A} bare-assert 1\n"
    status = run(check, repo, baseline, "--summary", "--all")
    out = capsys.readouterr().out
    assert_that(status).is_equal_to(0)
    assert_that(out).contains("bare-assert: 1 in 1 files")
    assert_that(out).contains("unittest-class: 0 in 0 files")
    assert_that(out).contains("missing-docstring: 0 in 0 files")
    assert_that(out).contains(f"{TEST_A}:3: [bare-assert]")


def test_repository_matches_baseline(check: ModuleType) -> None:
    """The checked-in tests match the committed baseline exactly."""
    offences, errors = check.check(check.ROOT)
    baseline = check.BASELINE.read_text(encoding="utf-8")
    allowed, baseline_errors = check.parse_baseline(baseline)
    assert_that(errors + baseline_errors).is_empty()
    assert_that(check.compare(offences, allowed)).is_empty()
