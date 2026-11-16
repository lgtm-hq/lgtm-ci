# SPDX-License-Identifier: MIT
"""CLI contract of the Python release ecosystem readers and updaters (#1423).

``python.sh`` reads the current version with ``read-pyproject-field.py`` and
``read-uv-lock-version.py`` and writes the new one with
``update-python-version.py`` and ``update-uv-lock-version.py``. A reader that
prints the wrong entry, or an updater that half-writes a file or exits 0 on
bad input, ships a wrong version in the release PR. Each script runs as a child
process here, the way the release job calls it; the subprocess patch in
``[tool.coverage.run]`` measures those runs.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ECOSYSTEMS = PROJECT_ROOT / "scripts" / "ci" / "release" / "ecosystems"
READ_FIELD = ECOSYSTEMS / "read-pyproject-field.py"
UPDATE_VERSION = ECOSYSTEMS / "update-python-version.py"
READ_LOCK = ECOSYSTEMS / "read-uv-lock-version.py"
UPDATE_LOCK = ECOSYSTEMS / "update-uv-lock-version.py"

# Chmod-based unreadable/unwritable files do not stop root.
needs_non_root = pytest.mark.skipif(
    os.geteuid() == 0,
    reason="root bypasses file permissions",
)

PYPROJECT = """\
# Release metadata; comments must survive a version bump.
[project]
name = "demo"
version = "1.2.3"  # bumped by the release PR
description = "Demo package"

[tool.other]
version = "9.9.9"
"""

# The same name locked twice: the project itself (editable) and a registry
# package. Readers must prefer the local entry, as the updater does.
LOCK = """\
version = 1
revision = 3
requires-python = ">=3.11"

[[package]]
name = "demo"
version = "0.5.0"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "demo"
version = "1.2.3"
source = { editable = "." }

[[package]]
name = "requests"
version = "2.32.3"
source = { registry = "https://pypi.org/simple" }
"""


def run_script(script: Path, *args: str | Path) -> subprocess.CompletedProcess[str]:
    """Run a release ecosystem script with the test interpreter.

    Args:
        script: Script to run.
        *args: Command-line arguments.

    Returns:
        The finished process with text output.
    """
    return subprocess.run(
        [sys.executable, str(script), *map(str, args)],
        capture_output=True,
        text=True,
        check=False,
    )


def write(path: Path, content: str) -> Path:
    """Write ``content`` to ``path`` and return the path."""
    path.write_text(content, encoding="utf-8")
    return path


@pytest.mark.parametrize(
    ("field", "expected"),
    [("version", "1.2.3"), ("name", "demo"), ("license", "")],
)
def test_read_field_prints_project_table_values(
    tmp_path: Path,
    field: str,
    expected: str,
) -> None:
    """Fields come from [project] only; an absent field prints an empty line."""
    pyproject = write(tmp_path / "pyproject.toml", PYPROJECT)
    result = run_script(READ_FIELD, pyproject, field)
    assert_that(result.returncode).described_as(result.stderr).is_zero()
    assert_that(result.stdout).is_equal_to(f"{expected}\n")


def test_read_field_without_project_table_prints_empty(tmp_path: Path) -> None:
    """A tool-only pyproject has no version to read, which is not an error."""
    pyproject = write(tmp_path / "pyproject.toml", '[tool.x]\nversion = "1"\n')
    result = run_script(READ_FIELD, pyproject, "version")
    assert_that(result.returncode).is_zero()
    assert_that(result.stdout).is_equal_to("\n")


@pytest.mark.parametrize(
    ("args", "message"),
    [
        pytest.param(["only-one-arg"], "Usage:", id="usage"),
        pytest.param(["missing.toml", "version"], "does not exist", id="missing"),
    ],
)
def test_read_field_rejects_bad_invocations(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    args: list[str],
    message: str,
) -> None:
    """Usage errors and a missing file exit 1 with nothing on stdout."""
    monkeypatch.chdir(tmp_path)
    result = run_script(READ_FIELD, *args)
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains(message)
    assert_that(result.stdout).is_empty()


def test_read_field_fails_on_invalid_toml(tmp_path: Path) -> None:
    """A corrupt pyproject must fail, not read as "no version"."""
    pyproject = write(tmp_path / "pyproject.toml", "[project\nversion = 1\n")
    result = run_script(READ_FIELD, pyproject, "version")
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains("failed to parse")
    assert_that(result.stdout).is_empty()


@needs_non_root
def test_read_field_fails_on_unreadable_file(tmp_path: Path) -> None:
    """An unreadable pyproject is reported as such."""
    pyproject = write(tmp_path / "pyproject.toml", PYPROJECT)
    pyproject.chmod(0o000)
    try:
        result = run_script(READ_FIELD, pyproject, "version")
    finally:
        pyproject.chmod(0o644)
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains("cannot read")


def test_update_version_changes_only_the_project_version(tmp_path: Path) -> None:
    """Only [project].version changes; comments and other tables stay."""
    pyproject = write(tmp_path / "pyproject.toml", PYPROJECT)
    result = run_script(UPDATE_VERSION, pyproject, "2.0.0")
    assert_that(result.returncode).described_as(result.stderr).is_zero()
    assert_that(pyproject.read_text(encoding="utf-8")).is_equal_to(
        PYPROJECT.replace('version = "1.2.3"', 'version = "2.0.0"'),
    )
    assert_that(run_script(READ_FIELD, pyproject, "version").stdout).is_equal_to(
        "2.0.0\n",
    )


@pytest.mark.parametrize(
    ("content", "message"),
    [
        pytest.param('[tool.x]\nversion = "1"\n', "no [project] table", id="no-table"),
        pytest.param(
            '[project]\nname = "demo"\ndynamic = ["version"]\n',
            "no version key",
            id="dynamic-version",
        ),
        pytest.param("[project\n", "failed to parse", id="invalid-toml"),
    ],
)
def test_update_version_fails_closed_without_writing(
    tmp_path: Path,
    content: str,
    message: str,
) -> None:
    """A pyproject the updater cannot bump exits 1 and stays unchanged."""
    pyproject = write(tmp_path / "pyproject.toml", content)
    result = run_script(UPDATE_VERSION, pyproject, "2.0.0")
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains(message)
    assert_that(pyproject.read_text(encoding="utf-8")).is_equal_to(content)


@pytest.mark.parametrize(
    ("args", "message"),
    [
        pytest.param(["pyproject.toml"], "Usage:", id="usage"),
        pytest.param(["missing.toml", "2.0.0"], "does not exist", id="missing"),
    ],
)
def test_update_version_rejects_bad_invocations(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    args: list[str],
    message: str,
) -> None:
    """Usage errors and a missing file exit 1."""
    monkeypatch.chdir(tmp_path)
    result = run_script(UPDATE_VERSION, *args)
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains(message)


@needs_non_root
@pytest.mark.parametrize(
    ("mode", "message"),
    [(0o000, "cannot read"), (0o444, "cannot write")],
)
def test_update_version_reports_permission_failures(
    tmp_path: Path,
    mode: int,
    message: str,
) -> None:
    """Unreadable or read-only files fail with the reason, not a traceback."""
    pyproject = write(tmp_path / "pyproject.toml", PYPROJECT)
    pyproject.chmod(mode)
    try:
        result = run_script(UPDATE_VERSION, pyproject, "2.0.0")
    finally:
        pyproject.chmod(0o644)
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains(message).does_not_contain("Traceback")
    assert_that(pyproject.read_text(encoding="utf-8")).is_equal_to(PYPROJECT)


@pytest.mark.parametrize(
    ("args", "expected"),
    [
        pytest.param(["demo"], "1.2.3", id="prefers-local-entry"),
        pytest.param(["demo", "--local-only"], "1.2.3", id="local-only"),
        pytest.param(["requests"], "2.32.3", id="registry-only-package"),
        pytest.param(["requests", "--local-only"], "", id="local-only-no-local"),
        pytest.param(["absent"], "", id="not-locked"),
    ],
)
def test_read_lock_selects_the_project_entry(
    tmp_path: Path,
    args: list[str],
    expected: str,
) -> None:
    """The local entry wins over a same-name registry entry."""
    lock = write(tmp_path / "uv.lock", LOCK)
    result = run_script(READ_LOCK, lock, *args)
    assert_that(result.returncode).described_as(result.stderr).is_zero()
    assert_that(result.stdout).is_equal_to(f"{expected}\n")


@pytest.mark.parametrize(
    "args",
    [
        pytest.param(["uv.lock"], id="no-package"),
        pytest.param(["uv.lock", "demo", "extra"], id="extra-arg"),
        pytest.param(["uv.lock", "demo", "--project-dir"], id="dangling-flag"),
    ],
)
def test_read_lock_rejects_bad_usage(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    args: list[str],
) -> None:
    """A malformed command line exits 1 rather than guessing."""
    monkeypatch.chdir(tmp_path)
    write(tmp_path / "uv.lock", LOCK)
    result = run_script(READ_LOCK, *args)
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains("Usage:")
    assert_that(result.stdout).is_empty()


@pytest.mark.parametrize(
    ("content", "message"),
    [
        pytest.param(None, "does not exist", id="missing"),
        pytest.param("[[package]\n", "failed to parse", id="invalid-toml"),
    ],
)
def test_read_lock_fails_on_missing_or_corrupt_lock(
    tmp_path: Path,
    content: str | None,
    message: str,
) -> None:
    """A lock the reader cannot parse must not read as "not locked"."""
    lock = tmp_path / "uv.lock"
    if content is not None:
        write(lock, content)
    result = run_script(READ_LOCK, lock, "demo")
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains(message)
    assert_that(result.stdout).is_empty()


@needs_non_root
def test_read_lock_fails_on_unreadable_lock(tmp_path: Path) -> None:
    """An unreadable lock is reported as such."""
    lock = write(tmp_path / "uv.lock", LOCK)
    lock.chmod(0o000)
    try:
        result = run_script(READ_LOCK, lock, "demo")
    finally:
        lock.chmod(0o644)
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains("cannot read")


def test_update_lock_leaves_other_versions_of_the_name_alone(tmp_path: Path) -> None:
    """A sourceless pin of another version still points at that version."""
    content = LOCK + (
        '\n[[package]]\nname = "app"\nversion = "0.1.0"\n'
        'source = { virtual = "app" }\n'
        'dependencies = [{ name = "demo", version = "0.5.0" }]\n'
    )
    lock = write(tmp_path / "uv.lock", content)
    result = run_script(UPDATE_LOCK, lock, "demo", "2.0.0")
    assert_that(result.returncode).described_as(result.stderr).is_zero()
    assert_that(run_script(READ_LOCK, lock, "demo").stdout).is_equal_to("2.0.0\n")
    text = lock.read_text(encoding="utf-8")
    assert_that(text).contains('version = "0.5.0"\nsource = { registry')
    assert_that(text).contains('{ name = "demo", version = "0.5.0" }')


@pytest.mark.parametrize(
    ("content", "message"),
    [
        pytest.param(None, "does not exist", id="missing"),
        pytest.param("version = 1\n", "no [[package]] entries", id="no-packages"),
    ],
)
def test_update_lock_fails_without_packages(
    tmp_path: Path,
    content: str | None,
    message: str,
) -> None:
    """A missing lock or one without packages exits 1."""
    lock = tmp_path / "uv.lock"
    if content is not None:
        write(lock, content)
    result = run_script(UPDATE_LOCK, lock, "demo", "2.0.0")
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains(message)


@needs_non_root
def test_update_lock_write_failure_keeps_the_lock(tmp_path: Path) -> None:
    """When the directory is read-only the lock stays as it was."""
    lock = write(tmp_path / "uv.lock", LOCK)
    tmp_path.chmod(0o555)
    try:
        result = run_script(UPDATE_LOCK, lock, "demo", "2.0.0")
    finally:
        tmp_path.chmod(0o755)
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains("cannot write").does_not_contain("Traceback")
    assert_that(lock.read_text(encoding="utf-8")).is_equal_to(LOCK)
