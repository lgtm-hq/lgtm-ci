# SPDX-License-Identifier: MIT
"""Tests for the source-standard check (#1626).

``scripts/ci/quality/validate_source_standard.py`` fails on a module, class or
function under ``scripts/ci`` without a docstring and on a module over 400
lines that ``module-length-exceptions.txt`` does not list; the list may only
shrink against the base revision. The CI job ``🐍 Source Standard`` runs it on
the repository; so does :func:`test_repository_passes`.
"""

from __future__ import annotations

import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = "scripts/ci/quality/validate_source_standard.py"
DOCUMENTED = '"""A module."""\n'
LIST = "scripts/ci/quality/module-length-exceptions.txt"
ENTRY = "scripts/ci/big.py split planned in #1626\n"
OK = "OK: scripts/ci Python source meets the source standard"


@pytest.fixture(name="check", scope="module")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the check once per module."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository: one documented module, an empty list."""
    (tmp_path / "scripts" / "ci" / "quality").mkdir(parents=True)
    write(tmp_path, "ok.py", DOCUMENTED)
    listing(tmp_path, "# comment\n")
    return tmp_path


@pytest.fixture(autouse=True)
def _no_ci(monkeypatch: pytest.MonkeyPatch) -> None:
    """Run every test as outside GitHub Actions unless it says otherwise."""
    monkeypatch.delenv("GITHUB_ACTIONS", raising=False)
    monkeypatch.delenv("GITHUB_EVENT_NAME", raising=False)


def write(repo: Path, name: str, text: str) -> None:
    """Write a module ``name`` under the scratch repository's scripts/ci."""
    (repo / "scripts" / "ci" / name).write_text(text, encoding="utf-8")


def listing(repo: Path, text: str) -> None:
    """Write the scratch repository's exception list."""
    (repo / LIST).write_text(text, encoding="utf-8")


def run(check: ModuleType, repo: Path, *extra: str) -> int:
    """Run the check's ``main`` on a scratch repository and its list."""
    arguments = ["--repo-root", str(repo), "--exceptions", str(repo / LIST)]
    code: int = check.main([*arguments, *extra])
    return code


def long_module(lines: int) -> str:
    """Return a documented module of exactly ``lines`` lines."""
    return DOCUMENTED + "X = 1\n" * (lines - 1)


def git(repo: Path, *args: str) -> None:
    """Run git in the scratch repository, failing the test on an error."""
    subprocess.run(  # noqa: S603 - fixed argv
        ["git", "-C", str(repo), *args],  # noqa: S607 - git from PATH
        check=True,
        capture_output=True,
    )


def commit_all(repo: Path, message: str) -> None:
    """Commit everything in the scratch repository."""
    git(repo, "add", "-A")
    identity = ["-c", "user.name=test", "-c", "user.email=test@example.invalid"]
    unsigned = ["-c", "commit.gpgsign=false"]
    git(repo, *identity, *unsigned, "commit", "--quiet", "-m", message)


def test_repository_passes(
    check: ModuleType,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The repository's own scripts/ci source meets the standard."""
    assert_that(check.main(["--repo-root", str(ROOT), "--summary"])).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains("missing-docstring: 0")


def test_scratch_repository_passes(check: ModuleType, repo: Path) -> None:
    """A repository with documented short modules and an empty list passes."""
    assert_that(run(check, repo)).is_equal_to(0)


def test_every_definition_needs_a_docstring(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Module, class, nested, async and dunder definitions all count."""
    source = (
        "class Public:\n"
        "    def __repr__(self) -> str:\n"
        "        return ''\n"
        "\n"
        "def _private() -> None:\n"
        '    """Documented."""\n'
        "\n"
        "    def nested() -> None:\n"
        "        pass\n"
        "\n"
        "async def waiting() -> None:\n"
        "    pass\n"
    )
    write(repo, "bad.py", source)
    assert_that(run(check, repo)).is_equal_to(1)
    out = capsys.readouterr().out
    prefix = "scripts/ci/bad.py"
    assert_that(out).contains(
        f"{prefix}:1: [missing-docstring] module has no docstring",
        f"{prefix}:1: [missing-docstring] class Public has no docstring",
        f"{prefix}:2: [missing-docstring] function __repr__ has no docstring",
        f"{prefix}:8: [missing-docstring] function nested has no docstring",
        f"{prefix}:11: [missing-docstring] function waiting has no docstring",
    )
    assert_that(out).does_not_contain("_private has no docstring")


def test_init_is_documented_by_its_class(check: ModuleType, repo: Path) -> None:
    """``__init__`` needs no docstring of its own (pydoclint DOC301 forbids one)."""
    source = (
        '"""A module."""\n'
        "class Public:\n"
        '    """A class."""\n'
        "\n"
        "    def __init__(self) -> None:\n"
        "        self.x = 1\n"
    )
    write(repo, "init.py", source)
    assert_that(run(check, repo)).is_equal_to(0)


@pytest.mark.parametrize(
    "docstring",
    [pytest.param('""""""', id="empty"), pytest.param('"""   """', id="blank")],
)
def test_blank_docstring_counts_as_missing(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    docstring: str,
) -> None:
    """An empty or whitespace-only docstring documents nothing."""
    source = f'"""A module."""\ndef blank() -> None:\n    {docstring}\n'
    write(repo, "blank.py", source)
    assert_that(run(check, repo)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "scripts/ci/blank.py:2: [missing-docstring] function blank has no docstring",
    )


def test_init_outside_a_class_needs_a_docstring(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Only a constructor is documented by its class; a module function is not."""
    source = '"""A module."""\ndef __init__() -> None:\n    pass\n'
    write(repo, "loose.py", source)
    assert_that(run(check, repo)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "scripts/ci/loose.py:2: [missing-docstring] function __init__ has no docstring",
    )


def test_module_at_the_limit_passes(check: ModuleType, repo: Path) -> None:
    """A module of exactly 400 lines needs no exception entry."""
    write(repo, "edge.py", long_module(400))
    assert_that(run(check, repo)).is_equal_to(0)


def test_unlisted_long_module_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A module of 401 lines that the list does not name fails."""
    write(repo, "big.py", long_module(401))
    assert_that(run(check, repo)).is_equal_to(1)
    what = "401 lines, over the 400-line limit and not listed"
    assert_that(capsys.readouterr().out).contains(
        f"scripts/ci/big.py:1: [module-length] {what}",
    )


def test_listed_long_module_passes(check: ModuleType, repo: Path) -> None:
    """A long module listed with a reason passes."""
    write(repo, "big.py", long_module(500))
    listing(repo, ENTRY)
    assert_that(run(check, repo)).is_equal_to(0)


@pytest.mark.parametrize("lines", [400, 0], ids=["shrunk", "gone"])
def test_stale_entry_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    lines: int,
) -> None:
    """An entry whose module now fits, or is gone, fails until it is removed."""
    if lines:
        write(repo, "big.py", long_module(lines))
    listing(repo, ENTRY)
    assert_that(run(check, repo)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "scripts/ci/big.py: stale exception entry",
        "remove the entry",
    )


@pytest.mark.parametrize(
    ("text", "error"),
    [
        ("scripts/ci/big.py\n", "expected 'scripts/ci/<path>.py reason'"),
        ("other/big.py some reason\n", "expected 'scripts/ci/<path>.py reason'"),
        ("scripts/ci/a.py one\nscripts/ci/a.py two\n", "duplicate entry"),
    ],
    ids=["no-reason", "outside-scripts-ci", "duplicate"],
)
def test_bad_list_line_fails(check: ModuleType, text: str, error: str) -> None:
    """A list line without a reason, outside scripts/ci or repeated is an error."""
    _, errors = check.parse_exceptions(text)
    assert_that(errors).is_length(1)
    assert_that(errors[0]).contains(error)


def test_reason_may_hold_a_hash(check: ModuleType) -> None:
    """Only lines starting with # are comments; a reason keeps its issue number."""
    listed, errors = check.parse_exceptions(f"# head\n{ENTRY}")
    assert_that(errors).is_empty()
    assert_that(listed).is_equal_to({"scripts/ci/big.py": "split planned in #1626"})


def test_unparsable_module_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A module that does not parse or decode is an error, never skipped."""
    write(repo, "broken.py", "def (:\n")
    (repo / "scripts" / "ci" / "latin.py").write_bytes(b'"""calf\xe9"""\n')
    (repo / "scripts" / "ci" / "nul.py").write_bytes(b'"""A module."""\nx = 1\x00\n')
    assert_that(run(check, repo)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "scripts/ci/broken.py:1: does not parse",
        "scripts/ci/latin.py:1: does not read",
        "scripts/ci/nul.py:",
    )


def test_missing_source_tree_fails(
    check: ModuleType,
    tmp_path: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A repository root without scripts/ci is an error."""
    empty = tmp_path / "empty"
    empty.mkdir()
    code = check.main(["--repo-root", str(empty), "--exceptions", str(repo / LIST)])
    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("no such directory")


def test_unreadable_list_fails(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A missing exception list is an error."""
    (repo / LIST).unlink()
    assert_that(run(check, repo)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "ERROR: cannot read the exception list",
    )


def test_ratchet_fails_on_new_entry(
    check: ModuleType,
    repo: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An entry the base list does not have fails, even for a long module."""
    write(repo, "big.py", long_module(500))
    listing(repo, ENTRY)
    base = tmp_path / "base.txt"
    base.write_text("# empty\n", encoding="utf-8")
    assert_that(run(check, repo, "--base-exceptions", str(base))).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "The exception list grew against the base exception list",
        "scripts/ci/big.py: new exception entry",
    )


def test_ratchet_allows_removed_entry_and_new_reason(
    check: ModuleType,
    repo: Path,
    tmp_path: Path,
) -> None:
    """Dropping an entry or rewording a reason is allowed."""
    write(repo, "big.py", long_module(500))
    listing(repo, "scripts/ci/big.py a better reason\n")
    base = tmp_path / "base.txt"
    base.write_text("scripts/ci/big.py old\nscripts/ci/gone.py old\n", encoding="utf-8")
    assert_that(run(check, repo, "--base-exceptions", str(base))).is_equal_to(0)


def test_bad_base_line_fails(check: ModuleType, repo: Path, tmp_path: Path) -> None:
    """A malformed base list is an error, not an empty base."""
    base = tmp_path / "base.txt"
    base.write_text("not-a-path\n", encoding="utf-8")
    assert_that(run(check, repo, "--base-exceptions", str(base))).is_equal_to(1)


@pytest.fixture(name="history")
def fixture_history(repo: Path) -> Path:
    """Return the scratch repository as a git repository with no commit yet."""
    if shutil.which("git") is None:
        pytest.skip("git is not installed")
    git(repo, "init", "--quiet")
    return repo


def test_base_ref_before_the_check_establishes_the_list(
    check: ModuleType,
    history: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A base without the script predates the check: the first list is allowed."""
    (history / LIST).unlink()
    commit_all(history, "base")
    write(history, "big.py", long_module(500))
    listing(history, ENTRY)
    assert_that(run(check, history, "--base-ref", "HEAD")).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains("which predates the check")


def test_base_ref_with_script_and_no_list_allows_nothing(
    check: ModuleType,
    history: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A base that has the script but no list allows no entry."""
    (history / LIST).unlink()
    (history / SCRIPT_PATH).write_text(DOCUMENTED, encoding="utf-8")
    commit_all(history, "base")
    write(history, "big.py", long_module(500))
    listing(history, ENTRY)
    assert_that(run(check, history, "--base-ref", "HEAD")).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("which has no exception list")


def test_base_ref_reads_the_base_list(check: ModuleType, history: Path) -> None:
    """The base list is read from the base revision with git."""
    write(history, "big.py", long_module(500))
    listing(history, ENTRY)
    commit_all(history, "base")
    assert_that(run(check, history, "--base-ref", "HEAD")).is_equal_to(0)


def test_missing_base_ref_fails(
    check: ModuleType,
    history: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A base revision that is not in the checkout is an error."""
    commit_all(history, "base")
    assert_that(run(check, history, "--base-ref", "HEAD^1")).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "base revision HEAD^1 is not available",
    )


def test_pull_request_in_actions_reads_the_merge_parent(
    check: ModuleType,
    history: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """In a GitHub Actions pull_request run the base is HEAD^1."""
    commit_all(history, "base")
    write(history, "big.py", long_module(500))
    listing(history, ENTRY)
    commit_all(history, "head")
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    assert_that(run(check, history)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "The exception list grew against the exception list of HEAD^1",
    )


def test_push_in_actions_skips_the_ratchet(
    check: ModuleType,
    repo: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A push run skips the ratchet: the pull request already ran it."""
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "push")
    assert_that(run(check, repo)).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains(
        "a push, which the pull request already ratcheted",
    )


def test_summary_counts_each_rule(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """--summary prints the docstring count and the long and listed modules."""
    write(repo, "big.py", long_module(500))
    listing(repo, ENTRY)
    assert_that(run(check, repo, "--summary")).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains(
        "missing-docstring: 0",
        "module-length: 1 modules over 400 lines, 1 listed",
    )


def test_script_runs_as_a_file(repo: Path) -> None:
    """The script runs directly on the standard library alone, as CI runs it."""
    script = str(ROOT / SCRIPT_PATH)
    arguments = ["--repo-root", str(repo), "--exceptions", str(repo / LIST)]
    result = subprocess.run(  # noqa: S603 - fixed argv
        ["python3", "-I", script, *arguments],  # noqa: S607 - python3 from PATH
        capture_output=True,
        text=True,
        check=False,
    )
    assert_that(result.returncode).is_equal_to(0)
    assert_that(result.stdout).contains(OK)
