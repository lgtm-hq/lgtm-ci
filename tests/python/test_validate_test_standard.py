# SPDX-License-Identifier: MIT
"""Tests for the test-standard check (#1625).

``scripts/ci/quality/validate_test_standard.py`` reports bare ``assert``
statements, ``unittest.TestCase`` classes and test functions without a
docstring under ``tests/``, against a baseline that may only shrink. The CI
job ``🧪 Test Standard`` runs it on the repository; so does
:func:`test_repository_matches_baseline`.
"""

from __future__ import annotations

import os
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from standard_check_support import SCRIPT_PATH, empty_repo, rendered, source, write

TEST_A = "tests/python/test_a.py"
BARE = "[bare-assert] bare assert; use assertpy (assert_that)"
NO_DOC = "has no docstring saying what it proves"

pytestmark = pytest.mark.usefixtures("no_github_ci")


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
    empty_repo(tmp_path)
    return tmp_path


def run(check: ModuleType, repo: Path, baseline: str, *flags: str) -> int:
    """Run ``main`` on the repository with a baseline file of the given text."""
    path = repo / "baseline.txt"
    path.write_text(baseline, encoding="utf-8")
    argv = ["--repo-root", str(repo), "--baseline", str(path), *flags]
    return int(check.main(argv))


def test_github_ci_variables_are_cleared_for_every_test() -> None:
    """A CI run of these tests does not switch the check to its CI ratchet."""
    names = ("ACTIONS", "EVENT_NAME", "BASE_REF", "HEAD_REF")
    set_names = [name for name in names if f"GITHUB_{name}" in os.environ]
    assert_that(set_names).is_empty()


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
    ("header", "base"),
    [
        pytest.param("import unittest", "unittest.TestCase", id="attribute"),
        pytest.param("from unittest import TestCase", "TestCase", id="imported-name"),
        pytest.param(
            "import unittest",
            "unittest.IsolatedAsyncioTestCase",
            id="async-case",
        ),
        pytest.param("import unittest as ut", "ut.TestCase", id="module-alias"),
        pytest.param("from unittest import TestCase as T", "T", id="name-alias"),
        pytest.param(
            "from unittest import IsolatedAsyncioTestCase as T",
            "T",
            id="async-name-alias",
        ),
        pytest.param(
            "import unittest\nBase = unittest.TestCase",
            "Base",
            id="assignment",
        ),
        pytest.param(
            "from unittest.case import TestCase",
            "TestCase",
            id="case-module",
        ),
        pytest.param("from unittest import *", "TestCase", id="star-import"),
        pytest.param(
            "if True:\n    from unittest import TestCase as T",
            "T",
            id="conditional-import",
        ),
    ],
)
def test_testcase_class_is_reported(
    check: ModuleType,
    repo: Path,
    header: str,
    base: str,
) -> None:
    """A class deriving from a unittest case class is reported under any alias."""
    write(repo, TEST_A, source(header, f"class Cases({base}):", "    pass"))
    line = header.count("\n") + 2
    assert_that(rendered(check, repo)).is_equal_to(
        [
            f"{TEST_A}:{line}: [unittest-class] class Cases is a unittest.TestCase; "
            "use pytest functions",
        ],
    )


@pytest.mark.parametrize(
    ("path", "header", "base"),
    [
        pytest.param(
            "tests/helpers/cases.py",
            "from support import Base as B",
            "B",
            id="sibling-alias",
        ),
        pytest.param(
            "tests/python/test_cases.py",
            "from tests.helpers.support import Base as B",
            "B",
            id="absolute-alias",
        ),
        pytest.param(
            "tests/helpers/cases.py",
            "from .support import Base",
            "Base",
            id="relative-import",
        ),
        pytest.param(
            "tests/python/test_cases.py",
            "import support as s",
            "s.Base",
            id="module-alias",
        ),
        pytest.param(
            "tests/python/test_cases.py",
            "from tests.helpers import support",
            "support.Base",
            id="submodule-import",
        ),
        pytest.param(
            "tests/python/test_cases.py",
            "from reexport import Base as B",
            "B",
            id="re-export",
        ),
    ],
)
def test_shared_base_imported_under_another_name_is_reported(
    check: ModuleType,
    repo: Path,
    path: str,
    header: str,
    base: str,
) -> None:
    """A case class whose shared base comes from another file, renamed, counts."""
    shared = source("import unittest", "class Base(unittest.TestCase):", "    pass")
    write(repo, "tests/helpers/support.py", shared)
    write(repo, "tests/helpers/reexport.py", source("from support import Base"))
    write(repo, path, source(header, f"class Cases({base}):", "    pass"))
    files = sorted(line.split(":", 1)[0] for line in rendered(check, repo))
    assert_that(files).is_equal_to(sorted([path, "tests/helpers/support.py"]))


def test_unrelated_classes_sharing_a_name_are_not_reported(
    check: ModuleType,
    repo: Path,
) -> None:
    """Bases resolve by module and name: equal names elsewhere are unrelated."""
    shared = source("import unittest", "class Base(unittest.TestCase):", "    pass")
    write(repo, "tests/helpers/support.py", shared)
    write(repo, "tests/helpers/plain.py", source("class Base:", "    pass"))
    local = source(
        "class Base:",
        "    pass",
        "class TestCase:",
        "    pass",
        "class TestLocal(Base):",
        '    """Doc."""',
        "class TestNamed(TestCase):",
        '    """Doc."""',
    )
    write(repo, "tests/python/test_local.py", local)
    imported = source("from plain import Base", "class TestOther(Base):", "    pass")
    write(repo, "tests/helpers/test_other.py", imported)
    assert_that(rendered(check, repo)).is_equal_to(
        [
            "tests/helpers/support.py:2: [unittest-class] class Base is a "
            "unittest.TestCase; use pytest functions",
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


@pytest.mark.parametrize(
    "text",
    [
        pytest.param(source("if True:", "    def test_x():", "        pass"), id="if"),
        pytest.param(
            source(
                "try:",
                "    async def test_x():",
                "        pass",
                "except E:",
                "    pass",
            ),
            id="try-async",
        ),
        pytest.param(
            source("with ctx:", "    def test_x():", "        pass"),
            id="with",
        ),
        pytest.param(
            source(
                "class TestOuter:",
                '    """Doc."""',
                "    class TestInner:",
                "        def test_x(self):",
                "            pass",
            ),
            id="nested-class",
        ),
        pytest.param(
            source(
                "class TestGroup:",
                "    if True:",
                "        async def test_x(self):",
                "            pass",
            ),
            id="class-if-async",
        ),
        pytest.param(
            source(
                "import unittest",
                "class Cases(unittest.TestCase):",
                "    def test_x(self):",
                "        pass",
            ),
            id="unittest-class",
        ),
    ],
)
def test_collected_test_without_docstring_is_reported(
    check: ModuleType,
    repo: Path,
    text: str,
) -> None:
    """Tests pytest collects from control flow and nested classes need a docstring."""
    write(repo, TEST_A, text)
    reported = [line for line in rendered(check, repo) if "missing-docstring" in line]
    assert_that(reported).is_length(1)
    assert_that(reported[0]).contains(f"test_x {NO_DOC}")


def test_uncollected_functions_need_no_docstring(check: ModuleType, repo: Path) -> None:
    """Non-test classes, classes with ``__init__`` and function bodies are exempt."""
    text = source(
        "class Helper:",
        "    def test_helper_method(self):",
        "        pass",
        "class TestBuilder:",
        "    def __init__(self):",
        "        pass",
        "    def test_build(self):",
        "        pass",
        "if True:",
        "    def run():",
        "        def test_inner():",
        "            pass",
    )
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_empty()


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


@pytest.mark.parametrize(
    ("data", "expected"),
    [
        pytest.param(b"x = 1\n\xff\n", ":2: does not read: not UTF-8", id="not-utf-8"),
        pytest.param(None, ":1: does not read: ", id="unreadable"),
    ],
)
def test_unreadable_file_is_an_error(
    check: ModuleType,
    repo: Path,
    data: bytes | None,
    expected: str,
) -> None:
    """A test file that is not UTF-8 or cannot be read fails with its line."""
    path = repo / "tests/python/test_bad.py"
    path.parent.mkdir(parents=True)
    if data is None:
        path.mkdir()  # A directory named like a test file: reading it fails.
    else:
        path.write_bytes(data)
    _, errors = check.check(repo)
    assert_that(errors).is_length(1)
    assert_that(errors[0]).starts_with(f"tests/python/test_bad.py{expected}")


def test_missing_tests_directory_is_an_error(check: ModuleType, tmp_path: Path) -> None:
    """A repository root without ``tests/`` fails instead of passing on nothing."""
    offences, errors = check.check(tmp_path)
    assert_that(offences).is_empty()
    assert_that(errors).is_length(1)
    assert_that(errors[0]).contains("no such directory; is --repo-root")


def test_unreadable_baseline_fails_with_a_message(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A missing baseline file fails with a message, not a traceback."""
    write(repo, TEST_A, CLEAN)
    missing = repo / "no-baseline.txt"
    status = check.main(["--repo-root", str(repo), "--baseline", str(missing)])
    assert_that(status).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        f"ERROR: cannot read the baseline {missing}",
    )


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
        pytest.param(f"{TEST_A} bare-assert ²", id="superscript-digit-count"),
        pytest.param(f"{TEST_A} bare-assert ٣", id="non-ascii-digit-count"),
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
