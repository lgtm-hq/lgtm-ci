# SPDX-License-Identifier: MIT
"""Tests for the workflow-file check of the version-PR reusables (#1449)."""

import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = "scripts/ci/release/check_workflow_file_changes.py"
WORKFLOW = ".github/workflows/build.yml"


def git(repo: Path, *args: str) -> None:
    """Run one git command in a test repository.

    Args:
        repo: The repository directory.
        *args: Arguments after ``git``.
    """
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            *args,
        ],
        cwd=repo,
        check=True,
        capture_output=True,
    )


@pytest.fixture(name="checker")
def fixture_checker(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the check as a module."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Create a committed repository with one workflow and one version file."""
    repo = tmp_path / "repo"
    (repo / ".github/workflows").mkdir(parents=True)
    (repo / WORKFLOW).write_text("name: build\nenv:\n  VERSION: 1.0.0\n")
    (repo / "VERSION").write_text("1.0.0\n")
    (repo / "CHANGELOG.md").write_text("# Changelog\n")
    git(repo, "init", "--quiet", "--initial-branch=main")
    git(repo, "add", "--all")
    git(repo, "commit", "--quiet", "--message", "initial")
    return repo


def run_check(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> tuple[int, str]:
    """Run the check against a repository.

    Args:
        checker: The loaded script module.
        repo: The repository to inspect.
        capsys: Pytest's output capture.

    Returns:
        The exit status and everything the check printed.
    """
    status: int = checker.main(["--repo-root", str(repo)])
    return status, capsys.readouterr().out


def test_passes_when_only_version_files_changed(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Version files, staged files and new files elsewhere are allowed."""
    (repo / "VERSION").write_text("1.1.0\n")
    (repo / "CHANGELOG.md").write_text("# Changelog\n\n## 1.1.0\n")
    git(repo, "add", "CHANGELOG.md")
    (repo / ".github/dependabot.yml").write_text("version: 2\n")
    (repo / "docs").mkdir()
    (repo / "docs/.github-workflows-notes.md").write_text("notes\n")

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_that(status).is_equal_to(0)
    assert_that(output).does_not_contain("::error")


def test_passes_on_a_clean_tree(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """No change at all is not a workflow change."""
    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_that(status).is_equal_to(0)
    assert_that(output).does_not_contain("::error")


def assert_refused(status: int, output: str, path: str) -> None:
    """Assert the check failed and told the caller what to do.

    Args:
        status: The exit status of the check.
        output: What the check printed.
        path: A workflow path the error must name.
    """
    assert_that(status).is_equal_to(1)
    line = next(line for line in output.splitlines() if f"::{path} changed" in line)
    assert_that(line).starts_with("::error title=workflow file changed::")
    assert_that(line).contains("request-workflows-permission: true")
    assert_that(line).contains('"Workflows: Read and write"')


def test_fails_on_a_modified_workflow_file(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An updater that rewrites a version inside a workflow is refused."""
    (repo / "VERSION").write_text("1.1.0\n")
    (repo / WORKFLOW).write_text("name: build\nenv:\n  VERSION: 1.1.0\n")

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=WORKFLOW)
    assert_that(output).does_not_contain("VERSION changed")


def test_fails_on_a_staged_workflow_file(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A change already in the index counts like one in the working tree."""
    (repo / WORKFLOW).write_text("name: build\nenv:\n  VERSION: 1.1.0\n")
    git(repo, "add", WORKFLOW)

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=WORKFLOW)


def test_fails_on_an_untracked_workflow_file(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A new workflow file is refused, in a new subdirectory too."""
    (repo / ".github/workflows/new.yml").write_text("name: new\n")
    (repo / ".github/workflows/nested").mkdir()
    (repo / ".github/workflows/nested/data.json").write_text("{}\n")

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=".github/workflows/new.yml")
    assert_refused(
        status=status,
        output=output,
        path=".github/workflows/nested/data.json",
    )


def test_fails_when_the_whole_workflows_directory_is_untracked(
    checker: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Git may not collapse an untracked directory and hide the file."""
    repo = tmp_path / "bare"
    repo.mkdir()
    (repo / "VERSION").write_text("1.0.0\n")
    git(repo, "init", "--quiet", "--initial-branch=main")
    git(repo, "add", "--all")
    git(repo, "commit", "--quiet", "--message", "initial")
    (repo / ".github/workflows").mkdir(parents=True)
    (repo / WORKFLOW).write_text("name: build\n")

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=WORKFLOW)


def test_fails_on_a_workflow_renamed_out_of_the_directory(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The source of a rename is a deletion under the protected path."""
    git(repo, "mv", WORKFLOW, "build.yml")

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=WORKFLOW)


def test_fails_on_a_file_renamed_into_the_directory(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The destination of a rename is a new workflow file."""
    git(repo, "mv", "VERSION", ".github/workflows/VERSION")

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=".github/workflows/VERSION")


def test_fails_on_a_deleted_workflow_file(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Deleting a workflow needs the permission as well."""
    (repo / WORKFLOW).unlink()

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=WORKFLOW)


def test_names_a_path_with_spaces_and_non_ascii_characters(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """NUL-separated output keeps unusual names unquoted and whole."""
    path = ".github/workflows/déploy site.yml"
    (repo / path).write_text("name: deploy\n")

    status, output = run_check(checker=checker, repo=repo, capsys=capsys)

    assert_refused(status=status, output=output, path=path)


def test_runs_from_a_subdirectory_of_the_repository(
    checker: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Paths stay relative to the repository root, whatever the start point."""
    (repo / "pkg").mkdir()
    (repo / WORKFLOW).write_text("name: changed\n")

    status, output = run_check(checker=checker, repo=repo / "pkg", capsys=capsys)

    assert_refused(status=status, output=output, path=WORKFLOW)


def test_fails_closed_outside_a_repository(
    checker: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A git failure is an error, never a pass."""
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path.parent))

    status, output = run_check(checker=checker, repo=tmp_path, capsys=capsys)

    assert_that(status).is_equal_to(2)
    assert_that(output).contains("::error title=workflow file check failed::")


def test_parse_status_reads_both_paths_of_a_rename_and_a_copy(
    checker: ModuleType,
) -> None:
    """Rename and copy entries carry a second NUL-terminated path."""
    raw = "R  new.yml\0old.yml\0 M plain.txt\0C  copy.yml\0origin.yml\0?? extra\0"

    assert_that(checker.parse_status(raw=raw)).is_equal_to(
        ["new.yml", "old.yml", "plain.txt", "copy.yml", "origin.yml", "extra"],
    )


def test_escapes_workflow_command_characters(checker: ModuleType) -> None:
    """A path cannot inject a second workflow command."""
    escaped = checker.escape_command_data(value="a%b\nc\rd")

    assert_that(escaped).is_equal_to("a%25b%0Ac%0Dd")


def test_command_line_entry_point_reports_the_path(repo: Path) -> None:
    """The file runs as the workflow calls it, from the caller's checkout."""
    (repo / WORKFLOW).write_text("name: changed\n")

    result = subprocess.run(
        [sys.executable, str(ROOT / SCRIPT_PATH)],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )

    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stdout).contains(f"::{WORKFLOW} changed")
