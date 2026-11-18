# SPDX-License-Identifier: MIT
"""Tests for the baseline ratchet of the test-standard check (#1625).

``validate_test_standard.py`` compares the baseline of a change with the
base revision's and fails on a new entry or a raised count. These tests pass
the base as a file, or build a throwaway git repository for ``--base-ref``
and the CI default (``HEAD^1`` on a pull request).
"""

from __future__ import annotations

import ast
import contextlib
import io
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/quality/validate_test_standard.py"
SCAN_PATH = "scripts/ci/quality/standard_scan.py"
BASELINE_PATH = "scripts/ci/quality/test-standard-baseline.txt"
TEST_A = "tests/python/test_a.py"
TWO_ASSERTS = "def test_a():\n    '''Doc.'''\n    assert 1\n    assert 2\n"
ENTRY = f"{TEST_A} bare-assert 2\n"


@pytest.fixture(name="check", scope="module")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Return a repository with one test file holding two bare asserts.

    The GitHub Actions variables are cleared so a CI run of these tests does
    not switch the check to its pull-request default.
    """
    monkeypatch.delenv("GITHUB_ACTIONS", raising=False)
    monkeypatch.delenv("GITHUB_EVENT_NAME", raising=False)
    path = tmp_path / TEST_A
    path.parent.mkdir(parents=True)
    path.write_text(TWO_ASSERTS, encoding="utf-8")
    (tmp_path / "baseline.txt").write_text(ENTRY, encoding="utf-8")
    return tmp_path


def run(check: ModuleType, repo: Path, *flags: str) -> int:
    """Run ``main`` on the repository with its ``baseline.txt``."""
    argv = ["--repo-root", str(repo), "--baseline", str(repo / "baseline.txt"), *flags]
    return int(check.main(argv))


GIT_IDENTITY = ("user.name=test", "user.email=test@example.invalid")


def git(repo: Path, *args: str) -> None:
    """Run git in a throwaway repository, unsigned and with a fixed identity."""
    settings: list[str] = []
    for value in (*GIT_IDENTITY, "commit.gpgsign=false"):
        settings += ["-c", value]
    argv = ["git", "-C", str(repo), *settings, *args]
    subprocess.run(argv, check=True, capture_output=True)  # noqa: S603


def commit(repo: Path, files: dict[str, str | None]) -> None:
    """Write (or, for ``None``, delete) files and commit them all."""
    for relative, text in files.items():
        path = repo / relative
        if text is None:
            path.unlink(missing_ok=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    git(repo, "add", "--all")
    git(repo, "commit", "--quiet", "--allow-empty", "-m", "commit")


@pytest.mark.parametrize(
    ("base", "expected"),
    [
        pytest.param(
            {},
            [f"{TEST_A}: new baseline entry bare-assert 2"],
            id="new-entry",
        ),
        pytest.param(
            {(TEST_A, "bare-assert"): 1},
            [f"{TEST_A}: baseline entry bare-assert 1 raised to 2"],
            id="raised-count",
        ),
        pytest.param({(TEST_A, "bare-assert"): 2}, [], id="unchanged"),
        pytest.param({(TEST_A, "bare-assert"): 5}, [], id="lowered"),
        pytest.param(
            {(TEST_A, "bare-assert"): 2, ("tests/gone.py", "bare-assert"): 1},
            [],
            id="removed-entry",
        ),
    ],
)
def test_ratchet_allows_only_shrinking(
    check: ModuleType,
    base: dict[tuple[str, str], int],
    expected: list[str],
) -> None:
    """A new entry or a raised count is reported; lower and removed ones are not."""
    allowed = {(TEST_A, "bare-assert"): 2}
    assert_that(check.ratchet(allowed, base)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("base", "status"),
    [
        pytest.param(f"{TEST_A} bare-assert 1\n", 1, id="raised"),
        pytest.param("# no entries\n", 1, id="new-entry"),
        pytest.param(ENTRY, 0, id="unchanged"),
        pytest.param(
            f"{TEST_A} bare-assert 3\ntests/b.py bare-assert 1\n",
            0,
            id="shrunk",
        ),
    ],
)
def test_baseline_grown_against_base_file_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    base: str,
    status: int,
) -> None:
    """``--base-baseline`` fails a baseline edited to allow more than the base."""
    (repo / "base.txt").write_text(base, encoding="utf-8")
    status_found = run(check, repo, "--base-baseline", str(repo / "base.txt"))
    assert_that(status_found).is_equal_to(status)
    out = capsys.readouterr().out
    if status:
        assert_that(out).contains("The baseline grew against the base baseline")
    else:
        assert_that(out).contains("OK: test code matches")


def test_unreadable_base_baseline_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A base baseline file that cannot be read fails closed."""
    status = run(check, repo, "--base-baseline", str(repo / "missing.txt"))
    assert_that(status).is_equal_to(1)
    out = capsys.readouterr().out
    assert_that(out).contains("ERROR: cannot read the base baseline")


def git_repo(repo: Path, base: dict[str, str | None]) -> None:
    """Commit a base revision, then the change (the current files) on top."""
    git(repo, "init", "--quiet")
    current = {path: (repo / path).read_text(encoding="utf-8") for path in (TEST_A,)}
    commit(repo, {**base, TEST_A: current[TEST_A]})
    commit(repo, {BASELINE_PATH: ENTRY, SCRIPT_PATH: "# script\n"})


@pytest.mark.parametrize(
    ("base", "outcome"),
    [
        pytest.param(
            {BASELINE_PATH: f"{TEST_A} bare-assert 1\n", SCRIPT_PATH: "# script\n"},
            (1, "baseline entry bare-assert 1 raised to 2"),
            id="raised",
        ),
        pytest.param(
            {BASELINE_PATH: ENTRY, SCRIPT_PATH: "# script\n"},
            (0, "OK: test code matches"),
            id="unchanged",
        ),
        pytest.param(
            {SCRIPT_PATH: "# script\n"},
            (1, "HEAD~1, which has no baseline file; it may only shrink"),
            id="baseline-removed",
        ),
        pytest.param(
            {},
            (0, "Baseline ratchet skipped: HEAD~1, which predates the check"),
            id="bootstrap",
        ),
    ],
)
def test_base_ref_reads_the_base_baseline_with_git(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    base: dict[str, str | None],
    outcome: tuple[int, str],
) -> None:
    """``--base-ref`` compares with the base commit; only the check's PR bootstraps."""
    git_repo(repo, base)
    assert_that(run(check, repo, "--base-ref", "HEAD~1")).is_equal_to(outcome[0])
    assert_that(capsys.readouterr().out).contains(outcome[1])


@pytest.mark.parametrize(
    ("event", "outcome"),
    [
        pytest.param("pull_request", (1, "raised to 2"), id="pull-request"),
        pytest.param("merge_group", (1, "raised to 2"), id="merge-group"),
        pytest.param("push", (0, "Baseline ratchet skipped: a push"), id="push"),
    ],
)
def test_ci_compares_pull_requests_with_the_first_parent(
    check: ModuleType,
    repo: Path,
    monkeypatch: pytest.MonkeyPatch,
    event: str,
    outcome: tuple[int, str],
) -> None:
    """In GitHub Actions a pull request is ratcheted against HEAD^1; a push is not."""
    git_repo(repo, {BASELINE_PATH: f"{TEST_A} bare-assert 1\n", SCRIPT_PATH: "# s\n"})
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    monkeypatch.setenv("GITHUB_EVENT_NAME", event)
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        status = run(check, repo)
    assert_that(status).is_equal_to(outcome[0])
    assert_that(output.getvalue()).contains(outcome[1])


def test_unavailable_base_fails_closed(
    check: ModuleType,
    repo: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A pull request whose base commit cannot be read or fetched fails."""
    git(repo, "init", "--quiet")
    commit(repo, {})
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    assert_that(run(check, repo)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "ERROR: base revision HEAD^1 is not available",
    )


def test_old_python_fails_with_a_clear_error(
    check: ModuleType,
    repo: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Below the minimum Python the check stops with a message, not a traceback."""
    monkeypatch.setattr(sys, "version_info", (3, 8, 0))
    assert_that(run(check, repo)).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains("needs Python 3.9 or newer")


@pytest.mark.parametrize("path", [SCRIPT_PATH, SCAN_PATH])
def test_scripts_use_python_3_9_syntax_and_no_str_enum(
    check: ModuleType,
    path: str,
) -> None:
    """The check runs on an older system python3: 3.9 grammar, no ``StrEnum``."""
    text = (check.ROOT / path).read_text(encoding="utf-8")
    tree = ast.parse(text, feature_version=(3, 9))
    imports = [n for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)]
    names = {alias.name for node in imports for alias in node.names}
    assert_that(names).does_not_contain("StrEnum")


def test_scanned_files_is_not_collectable_by_pytest(check: ModuleType) -> None:
    """The file lister has no ``test_`` name pytest would collect when imported."""
    assert_that(hasattr(check, "scanned_files")).is_true()
    public = [name for name in check.__all__ if name.startswith("test")]
    assert_that(public).is_empty()
