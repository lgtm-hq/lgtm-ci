# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/security/remove_stale_suppressions.py``.

The remover drops the ``[[IgnoredVulns]]`` blocks whose ``id`` is listed in
``REMOVE_IDS_JSON`` and keeps every other line of ``.osv-scanner.toml`` as
written, including other sections and comments inside retained blocks.

Fixtures ``workspace`` and ``install_fixture`` come from
``tests/python/conftest.py``.
"""

from __future__ import annotations

import json
import os
import runpy
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
    """Each removed ID is reported once, in sorted order; unknown IDs are not."""
    path = workspace / TOML
    path.write_text(
        "".join(f'[[IgnoredVulns]]\nid = "{vuln_id}"\n' for vuln_id in "BAC"),
        encoding="utf-8",
    )

    run_main(remover, monkeypatch, path, ["C", "A", "NOT-THERE"])

    assert_that(capsys.readouterr().err).is_equal_to("Removed: A\nRemoved: C\n")
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(
        '[[IgnoredVulns]]\nid = "B"\n',
    )


@pytest.mark.parametrize("remove_ids", [[], ["NOT-THERE"]])
def test_leaves_the_file_unwritten_when_nothing_matches(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    remove_ids: list[str],
) -> None:
    """With nothing to remove the file is not rewritten at all."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)
    original = path.read_text(encoding="utf-8")
    os.utime(path, ns=(1_000_000_000, 1_000_000_000))

    run_main(remover, monkeypatch, path, remove_ids)

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


@pytest.mark.parametrize(
    ("ids_json", "error"),
    [(None, KeyError), ("[not json", json.JSONDecodeError)],
)
def test_missing_or_malformed_ids_fail_without_writing(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    ids_json: str | None,
    error: type[Exception],
) -> None:
    """A missing or malformed ``REMOVE_IDS_JSON`` leaves the file untouched.

    The script fails with an unhandled error today (a traceback); a clean
    exit 1 would be just as acceptable, so both are allowed. What matters is
    that nothing is written.
    """
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)
    original = path.read_text(encoding="utf-8")
    if ids_json is None:
        monkeypatch.delenv("REMOVE_IDS_JSON", raising=False)
    else:
        monkeypatch.setenv("REMOVE_IDS_JSON", ids_json)
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])

    with pytest.raises((error, SystemExit)) as exc_info:
        remover.main()

    if isinstance(exc_info.value, SystemExit):
        assert_that(exc_info.value.code).is_not_equal_to(0)
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(original)


def test_missing_file_fails(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A path that does not exist is an error, and nothing is created."""
    path = workspace / TOML

    with pytest.raises(FileNotFoundError):
        run_main(remover, monkeypatch, path, ["A"])

    assert_that(path.exists()).is_false()


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


# --- remove_stale_ignored_vulns


def test_removes_every_block_with_a_listed_id(remover: ModuleType) -> None:
    """Duplicate blocks for one ID all go; the ID is reported once."""
    content = (
        '[[IgnoredVulns]]\nid = "DUP"\nreason = "one"\n\n'
        '[[IgnoredVulns]]\nid = "KEEP"\n\n'
        '[[IgnoredVulns]]\nid = "DUP"\nreason = "two"\n'
    )

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"DUP"})

    assert_that(rewritten).is_equal_to('[[IgnoredVulns]]\nid = "KEEP"\n\n')
    assert_that(removed).is_equal_to({"DUP"})


@pytest.mark.parametrize(
    "id_line",
    ['id = "X"', "id='X'", 'id   =   "X"  # trailing', '  id = "X"'],
)
def test_matches_id_spellings(remover: ModuleType, id_line: str) -> None:
    """Spacing, quote style, indentation and trailing comments do not matter."""
    content = f'[[IgnoredVulns]]\n{id_line}\nreason = "r"\n'

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_empty()
    assert_that(removed).is_equal_to({"X"})


def test_keeps_a_block_without_an_id(remover: ModuleType) -> None:
    """A block with no ``id`` line cannot match and is kept."""
    content = '[[IgnoredVulns]]\nreason = "no id"\n'

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_equal_to(content)
    assert_that(removed).is_empty()


def test_does_not_match_an_id_by_prefix(remover: ModuleType) -> None:
    """Only the exact ID matches, not one that starts with it."""
    content = '[[IgnoredVulns]]\nid = "GHSA-1234-extra"\n'

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"GHSA-1234"})

    assert_that(rewritten).is_equal_to(content)
    assert_that(removed).is_empty()


def test_block_ends_at_the_next_table_header(remover: ModuleType) -> None:
    """Removing the last suppression keeps a following table intact."""
    content = (
        '[[IgnoredVulns]]\nid = "X"\n\n'
        '[[PackageOverrides]]\nname = "ünïcode-pkg"\nignore = true\n'
    )

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_equal_to(
        '[[PackageOverrides]]\nname = "ünïcode-pkg"\nignore = true\n',
    )
    assert_that(removed).is_equal_to({"X"})


def test_handles_a_last_line_without_newline(remover: ModuleType) -> None:
    """A file that ends mid-block without a newline is still rewritten."""
    content = '[[IgnoredVulns]]\nid = "KEEP"\n[[IgnoredVulns]]\nid = "X"'

    rewritten, _ = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_equal_to('[[IgnoredVulns]]\nid = "KEEP"\n')


def test_empty_content(remover: ModuleType) -> None:
    """An empty file stays empty and removes nothing."""
    assert_that(remover.remove_stale_ignored_vulns("", {"X"})).is_equal_to(
        ("", set()),
    )
