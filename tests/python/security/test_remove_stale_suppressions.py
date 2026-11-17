# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/security/remove_stale_suppressions.py``.

The remover drops the ``[[IgnoredVulns]]`` blocks whose ``id`` is listed in
``REMOVE_IDS_JSON`` and keeps every other line of ``.osv-scanner.toml`` as
written. These tests run it as a command: what it prints, bad input, and the
atomic write. Bad input, a listed ID missing from the file, or an edit that
``tomllib`` cannot confirm or the disk cannot take ends in one ``ERROR:``
line and exit 1, and the file is left untouched. Line-editing rules are
tested in ``test_remove_stale_suppressions_layout.py``.

Fixtures ``workspace`` and ``install_fixture`` come from
``tests/python/conftest.py``.
"""

from __future__ import annotations

import errno
import json
import os
import runpy
import stat
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/security/remove_stale_suppressions.py"
PROJECT_ROOT = Path(__file__).resolve().parents[3]
TOML = ".osv-scanner.toml"

Installer = Callable[[str, str], Path]


@pytest.fixture(name="remover", scope="module")
def fixture_remover(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the remover once per module."""
    return load_script(SCRIPT)


@pytest.fixture(autouse=True)
def _no_inherited_id_list(monkeypatch: pytest.MonkeyPatch) -> None:
    """Drop an ID list from the developer's environment."""
    monkeypatch.delenv("REMOVE_IDS_JSON", raising=False)
    monkeypatch.delenv("REMOVE_IDS_FILE", raising=False)


def run_main(
    remover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    path: Path,
    remove_ids: list[str],
) -> None:
    """Run ``main`` on ``path`` with ``remove_ids`` in the environment.

    Args:
        remover: The loaded script module.
        monkeypatch: Fixture used to set ``sys.argv`` and the environment.
        path: The suppression TOML to rewrite.
        remove_ids: IDs passed through ``REMOVE_IDS_JSON``.
    """
    monkeypatch.setenv("REMOVE_IDS_JSON", json.dumps(remove_ids))
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])
    remover.main()


# --- main: ported from tests/bats/unit/security/test_remove_stale_suppressions.bats


def test_preserves_non_ignored_vulns_sections(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``[PackageOverrides]`` and the leading comment survive the rewrite."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)

    run_main(remover, monkeypatch, path, ["GHSA-stale-1111"])

    assert_that(capsys.readouterr().err).is_equal_to("Removed: GHSA-stale-1111\n")
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(
        "# Suppression config\n"
        "[PackageOverrides]\n"
        'path = "vendor/"\n'
        "\n"
        "[[IgnoredVulns]]\n"
        'id = "GHSA-active-2222"\n'
        "ignoreUntil = 2099-12-31\n"
        'reason = "still present"\n',
    )


def test_keeps_comments_inside_retained_blocks(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A comment inside a kept block stays with it."""
    path = install_fixture("security/osv-scanner-with-block-comments.toml", TOML)

    run_main(remover, monkeypatch, path, ["GHSA-stale-3333"])

    kept = [
        "[[IgnoredVulns]]",
        "# still relevant",
        'id = "GHSA-active-4444"',
        'reason = "active"',
    ]
    assert_that(path.read_text(encoding="utf-8").splitlines()).is_equal_to(kept)


def test_handles_a_single_quoted_id(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A literal-string ``id`` matches like a basic string."""
    path = install_fixture("security/osv-scanner-single-quoted-id.toml", TOML)

    run_main(remover, monkeypatch, path, ["GHSA-stale-XXXX"])

    assert_that(capsys.readouterr().err).contains("Removed: GHSA-stale-XXXX")
    text = path.read_text(encoding="utf-8")
    assert_that(text).does_not_contain("GHSA-stale-XXXX")
    assert_that(text).contains("GHSA-active-5555")


# --- main: beyond the bats suite


def test_reports_removed_ids_sorted(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Each removed ID is reported once, in sorted order."""
    path = workspace / TOML
    path.write_text(
        "".join(f'[[IgnoredVulns]]\nid = "{vuln_id}"\n' for vuln_id in "BAC"),
        encoding="utf-8",
    )

    run_main(remover, monkeypatch, path, ["C", "A"])

    assert_that(capsys.readouterr().err).is_equal_to("Removed: A\nRemoved: C\n")
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(
        '[[IgnoredVulns]]\nid = "B"\n',
    )


def test_reports_each_removed_comment_line(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Deleted comments, whole or inline, are listed by number, JSON-quoted.

    ``##[`` and ``::`` are escaped so the runner cannot read a deleted comment
    or an unusual ID as a command; a JSON reader still gets the same text.
    """
    path = workspace / TOML
    path.write_text(
        '[[IgnoredVulns]]\nid = "KEEP"\n\n# Why X ##[error]forged\n'
        '[[IgnoredVulns]] # X header note\nid = "X"\n# a "quote"\tand a tab\n'
        'reason = "gone # not a comment" # KEEP must be reviewed manually\n\n'
        '[[IgnoredVulns]]\nid = "Y##[error]forged::id"\n',
        encoding="utf-8",
    )

    run_main(remover, monkeypatch, path, ["X", "Y##[error]forged::id"])

    err = capsys.readouterr().err
    assert_that(err).is_equal_to(
        "Removed: X\n"
        'Removed: "Y#\\u0023[error]forged:\\u003aid"\n'
        'Removed comment line 4: "# Why X #\\u0023[error]forged"\n'
        'Removed comment line 5: "# X header note"\n'
        'Removed comment line 7: "# a \\"quote\\"\\tand a tab"\n'
        'Removed comment line 8: "# KEEP must be reviewed manually"\n',
    )
    assert_that(err).does_not_contain("##[").does_not_contain("::")


def test_reads_the_list_from_a_file(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``REMOVE_IDS_FILE`` carries lists too long for the environment."""
    path = workspace / TOML
    path.write_text('[[IgnoredVulns]]\nid = "A"\n', encoding="utf-8")
    ids_file = workspace / "ids.json"
    ids_file.write_text('["A"]\n', encoding="utf-8")
    monkeypatch.setenv("REMOVE_IDS_FILE", str(ids_file))
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])

    remover.main()

    assert_that(capsys.readouterr().err).is_equal_to("Removed: A\n")
    assert_that(path.read_text(encoding="utf-8")).is_empty()


def test_an_empty_list_leaves_the_file_unwritten(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """With nothing to remove the file is not rewritten at all."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)
    original = path.read_text(encoding="utf-8")
    os.utime(path, ns=(1_000_000_000, 1_000_000_000))

    run_main(remover, monkeypatch, path, [])

    assert_that(capsys.readouterr().err).is_empty()
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(original)
    assert_that(path.stat().st_mtime_ns).is_equal_to(1_000_000_000)


@pytest.mark.parametrize("argv", [[], ["a.toml", "b.toml"]])
def test_wrong_argument_count_is_a_usage_error(
    remover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    argv: list[str],
) -> None:
    """Anything but one path prints usage and exits 1."""
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", *argv])

    with pytest.raises(SystemExit) as exc_info:
        remover.main()

    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(capsys.readouterr().err).starts_with("Usage: ")


def assert_clean_failure(
    capsys: pytest.CaptureFixture[str],
    exc_info: pytest.ExceptionInfo[SystemExit],
    *messages: str,
) -> None:
    """Assert exit 1 and exactly one ``ERROR:`` line holding ``messages``."""
    err = capsys.readouterr().err
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(err.splitlines()).is_length(1)
    assert_that(err).starts_with("ERROR: ").contains(*messages)
    assert_that(err).ends_with("; the file was left unchanged\n")


@pytest.mark.parametrize(
    ("ids_json", "message"),
    [
        (None, "REMOVE_IDS_JSON or REMOVE_IDS_FILE must be set"),
        ("[not json", "REMOVE_IDS_JSON is not valid JSON"),
        ("", "REMOVE_IDS_JSON is not valid JSON"),
        ('{"A": 1}', "REMOVE_IDS_JSON must be a JSON array of strings"),
        ('"A"', "REMOVE_IDS_JSON must be a JSON array of strings"),
        ('["A", 1]', "REMOVE_IDS_JSON must be a JSON array of strings"),
        ("[null]", "REMOVE_IDS_JSON must be a JSON array of strings"),
        ("9" * 5000, "REMOVE_IDS_JSON is not valid JSON (Exceeds the limit"),
        ("[" * 100_000, "REMOVE_IDS_JSON is nested too deeply to read"),
    ],
    ids=["unset", "bad", "empty", "object", "string", "int", "null", "huge", "deep"],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_missing_or_malformed_ids_fail_without_writing(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    ids_json: str | None,
    message: str,
) -> None:
    """A missing or malformed ``REMOVE_IDS_JSON`` exits 1 with one error line."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)
    original = path.read_bytes()
    if ids_json is None:
        monkeypatch.delenv("REMOVE_IDS_JSON", raising=False)
    else:
        monkeypatch.setenv("REMOVE_IDS_JSON", ids_json)
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])

    with pytest.raises(SystemExit) as exc_info:
        remover.main()

    assert_clean_failure(capsys, exc_info, message)
    assert_that(path.read_bytes()).is_equal_to(original)


@pytest.mark.parametrize(
    ("ids_file", "both", "message"),
    [
        ("missing.json", False, "cannot read REMOVE_IDS_FILE ([Errno 2]"),
        ("ids.json", True, "set REMOVE_IDS_JSON or REMOVE_IDS_FILE, not both"),
        ("bad.json", False, "REMOVE_IDS_FILE is not valid JSON"),
        ("latin1.json", False, "cannot read REMOVE_IDS_FILE ("),
    ],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_an_unusable_list_file_fails_without_writing(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    ids_file: str,
    both: bool,
    message: str,
) -> None:
    """The file source fails as cleanly as the variable."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)
    original = path.read_bytes()
    (path.parent / "ids.json").write_text('["GHSA-stale-1111"]', encoding="utf-8")
    (path.parent / "bad.json").write_text("[not json", encoding="utf-8")
    (path.parent / "latin1.json").write_bytes(b'["\xff"]')
    monkeypatch.setenv("REMOVE_IDS_FILE", str(path.parent / ids_file))
    if both:
        monkeypatch.setenv("REMOVE_IDS_JSON", "[]")
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])

    with pytest.raises(SystemExit) as exc_info:
        remover.main()

    assert_clean_failure(capsys, exc_info, message)
    assert_that(path.read_bytes()).is_equal_to(original)


def test_missing_file_fails(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A path that does not exist is an error, and nothing is created."""
    path = workspace / TOML

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["A"])

    assert_clean_failure(capsys, exc_info, f"ERROR: {path} does not exist;")
    assert_that(path.exists()).is_false()


def test_unreadable_path_fails(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A path that cannot be read as a file is a clean error."""
    path = workspace / TOML
    path.mkdir()

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["A"])

    assert_clean_failure(capsys, exc_info, f"ERROR: cannot read {path} (")
    assert_that(path.is_dir()).is_true()


@pytest.mark.parametrize(
    ("content", "message"),
    [
        (b"[[IgnoredVulns]\nid = 'A'\n", ": not valid TOML ("),
        (b'[[IgnoredVulns]]\nid = "A"\nreason = "\xff"\n', " is not UTF-8 ("),
        (
            b'IgnoredVulns = [{id = "A"}]\n',
            ": found 0 [[IgnoredVulns]] header lines but tomllib reads 1 entries",
        ),
        (
            b'[[IgnoredVulns]]\nid = "KEEP"\n\n'
            b'[[IgnoredVulns]]\nid = "A"\nextra = [\n  ["a"]\n]\n',
            ": the edited file would not be valid TOML (",
        ),
        (
            b'[[IgnoredVulns]]\nid = "KEEP"\n\n'
            b'[[IgnoredVulns]]\nid = "A"\n[IgnoredVulns.note]\ntext = "x"\n',
            ": the edited file would change more than the listed suppressions",
        ),
        (
            b'[[IgnoredVulns]]\nid = "B"\n',
            ": REMOVE_IDS_JSON lists 1 ID(s) that are not in the file (A); the list",
        ),
        (
            b"x = " + b"[" * 5000 + b"]" * 5000 + b'\n[[IgnoredVulns]]\nid = "A"\n',
            ": not valid TOML (nested too deeply to read)",
        ),
        (
            b"x = " + b"9" * 5000 + b'\n[[IgnoredVulns]]\nid = "A"\n',
            ": not valid TOML (Exceeds the limit",
        ),
        (
            b'[[IgnoredVulns]]\nid = "A"\n\n['
            + b".".join(b"k%d" % number for number in range(600))
            + b"]\nv = 1\n",
            ": the file is nested too deeply to verify an edit",
        ),
    ],
    ids=[
        "bad-toml",
        "not-utf8",
        "inline-array",
        "invalid-result",
        "changed-result",
        "id-not-in-file",
        "deep-array",
        "huge-integer",
        "deep-table",
    ],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_unusable_or_unverifiable_file_is_not_written(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    content: bytes,
    message: str,
) -> None:
    """Bad input, or an edit ``tomllib`` does not confirm, writes nothing.

    In the last two cases the line editor and ``tomllib`` disagree: a nested
    array line looks like a ``["a"]`` table header, and ``[IgnoredVulns.note]``
    is a sub-table of the entry above it, not a separate block. Removing the
    block by line would break the file or move the note onto ``KEEP``.
    """
    path = workspace / TOML
    path.write_bytes(content)

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["A"])

    assert_clean_failure(capsys, exc_info, f"ERROR: {path}{message}")
    assert_that(path.read_bytes()).is_equal_to(content)


def test_runs_as_a_script(
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Run as ``__main__``, the remover rewrites the file it is given."""
    path = workspace / TOML
    path.write_text('[[IgnoredVulns]]\nid = "A"\n', encoding="utf-8")
    monkeypatch.setenv("REMOVE_IDS_JSON", '["A"]')
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])

    runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(capsys.readouterr().err).is_equal_to("Removed: A\n")
    assert_that(path.read_text(encoding="utf-8")).is_empty()


# --- writing the file


def stale_and_kept(path: Path) -> bytes:
    """Write a file with a stale ``X`` and a kept ``KEEP`` entry; return it."""
    content = b'[[IgnoredVulns]]\nid = "X"\n\n[[IgnoredVulns]]\nid = "KEEP"\n'
    path.write_bytes(content)
    return content


def leftovers(path: Path) -> list[str]:
    """Return the names next to ``path`` other than ``path`` itself."""
    return sorted(item.name for item in path.parent.iterdir() if item != path)


def test_replaces_the_file_and_keeps_its_mode(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The edit lands through a rename, with the mode kept and nothing left."""
    path = workspace / TOML
    stale_and_kept(path)
    path.chmod(0o640)
    before = leftovers(path)

    run_main(remover, monkeypatch, path, ["X"])

    assert_that(path.read_bytes()).is_equal_to(b'[[IgnoredVulns]]\nid = "KEEP"\n')
    assert_that(stat.S_IMODE(path.stat().st_mode)).is_equal_to(0o640)
    assert_that(leftovers(path)).is_equal_to(before)


@pytest.mark.parametrize("step", ["fsync", "replace"])
def test_a_failed_write_leaves_the_file_untouched(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    step: str,
) -> None:
    """A full disk while writing removes the temporary file; nothing changes."""
    path = workspace / TOML
    original = stale_and_kept(path)
    before = leftovers(path)

    def disk_full(*_args: object) -> None:
        raise OSError(errno.ENOSPC, "No space left on device")

    monkeypatch.setattr(remover.os, step, disk_full)

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["X"])

    assert_clean_failure(
        capsys,
        exc_info,
        f"ERROR: cannot write {path} ([Errno 28] No space left on device);",
    )
    assert_that(path.read_bytes()).is_equal_to(original)
    assert_that(leftovers(path)).is_equal_to(before)


def test_no_temporary_file_means_no_write(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """When no temporary file can be made, the original is not touched."""
    path = workspace / TOML
    original = stale_and_kept(path)

    def read_only(**_kwargs: object) -> None:
        raise OSError(errno.EROFS, "Read-only file system")

    monkeypatch.setattr(remover.tempfile, "mkstemp", read_only)

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["X"])

    assert_clean_failure(capsys, exc_info, "cannot create a temporary file for")
    assert_that(path.read_bytes()).is_equal_to(original)


def test_a_symbolic_link_is_refused(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Replacing a link would turn it into a file, so the edit is refused."""
    target = workspace / "real.toml"
    original = stale_and_kept(target)
    path = workspace / TOML
    path.symlink_to(target)

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["X"])

    assert_clean_failure(capsys, exc_info, f"ERROR: {path} is a symbolic link;")
    assert_that(path.is_symlink()).is_true()
    assert_that(target.read_bytes()).is_equal_to(original)
