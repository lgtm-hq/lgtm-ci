# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/security/format-security-comment.py``.

Covers the lintro result schemas the script consumes: the current
``metadata.suppressions`` key, the legacy ``ai_metadata`` key (py-lintro
< 0.95.0), neither key present, and suppressions present or absent.
"""

from __future__ import annotations

import json
import shutil
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/security/format-security-comment.py"

STALE_ROW = "| `GHSA-stale-2222` | 2099-12-31 | :warning: **Stale — safe to remove** |"
EXPIRED_ROW = "| :warning: `GHSA-expired-3333` | **EXPIRED** 2020-01-01 |"
ACTIVE_ROW = "| `GHSA-active-1111` | 2099-12-31 | Active | still present |"


@pytest.fixture(scope="module")
def formatter(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the formatter script once per module."""
    return load_script(SCRIPT)


@pytest.fixture
def workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Return an empty working directory the formatter reads TOML from."""
    monkeypatch.chdir(tmp_path)
    return tmp_path


def _install(fixtures_dir: Path, relative: str, dest: Path) -> Path:
    """Copy a committed fixture into the workspace.

    Args:
        fixtures_dir: The ``tests/fixtures`` directory.
        relative: Fixture path relative to ``fixtures_dir``.
        dest: Destination path.

    Returns:
        The destination path.
    """
    shutil.copyfile(fixtures_dir / relative, dest)
    return dest


@pytest.mark.parametrize(
    ("fixture", "expect_warning"),
    [
        ("security/osv-results-metadata-suppressions.json", False),
        ("security/osv-results-legacy-ai-metadata.json", True),
    ],
    ids=["schema=metadata", "schema=legacy-ai_metadata"],
)
def test_probe_suppressions_render_status_table(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
    fixture: str,
    expect_warning: bool,
) -> None:
    """Both schemas render the classified table; only legacy warns."""
    json_path = _install(fixtures_dir, fixture, workspace / "osv-results.json")

    output = formatter.format_comment(str(json_path))

    assert_that(output).is_not_none()
    assert_that(output).contains(ACTIVE_ROW, STALE_ROW, EXPIRED_ROW)
    assert_that(output).does_not_contain("No suppressions configured.")
    stderr = capsys.readouterr().err
    if expect_warning:
        assert_that(stderr).contains("legacy 'ai_metadata'", "lgtm-hq/lgtm-ci#825")
    else:
        assert_that(stderr).is_empty()


def test_metadata_key_wins_over_legacy_key(formatter: ModuleType) -> None:
    """When both keys are present the current key is read and legacy ignored."""
    result = {
        "tool": "osv_scanner",
        "metadata": {"suppressions": [{"id": "GHSA-new", "status": "stale"}]},
        "ai_metadata": {"suppressions": [{"id": "GHSA-old", "status": "active"}]},
    }

    suppressions = formatter._probe_suppressions(result)

    assert_that(suppressions).is_length(1)
    assert_that(suppressions[0]["id"]).is_equal_to("GHSA-new")


@pytest.mark.parametrize(
    "result",
    [
        {"tool": "osv_scanner"},
        {"tool": "osv_scanner", "metadata": {"fixed_count": 0}},
        {"tool": "osv_scanner", "metadata": {"suppressions": "nope"}},
        {"tool": "osv_scanner", "metadata": None, "ai_metadata": []},
    ],
    ids=["no-key", "metadata-without-suppressions", "non-list", "non-object"],
)
def test_probe_suppressions_none_without_list(
    formatter: ModuleType,
    result: dict[str, object],
) -> None:
    """Malformed or absent probe metadata yields ``None``, never a crash."""
    assert_that(formatter._probe_suppressions(result)).is_none()


def test_empty_probe_list_reports_no_suppressions(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
) -> None:
    """A probe that ran and classified nothing renders the empty message."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-clean.json",
        workspace / "osv-results.json",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        "No security vulnerabilities found in dependencies.",
        "No suppressions configured.",
    )


def test_neither_key_and_no_toml_reports_no_suppressions(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """No probe metadata and no TOML is the legitimate nothing-to-classify case."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-no-suppressions-meta.json",
        workspace / "osv-results.json",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains("No suppressions configured.")
    assert_that(capsys.readouterr().err).is_empty()


def test_neither_key_with_probe_eligible_toml_fails_loudly(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Missing probe metadata with classifiable TOML entries is an error."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-no-suppressions-meta.json",
        workspace / "osv-results.json",
    )
    _install(
        fixtures_dir,
        "security/osv-scanner-active-stale-expired.toml",
        workspace / ".osv-scanner.toml",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).is_none()
    stderr = capsys.readouterr().err
    assert_that(stderr).contains(
        "Suppression status unavailable",
        "'metadata.suppressions'",
        "'ai_metadata.suppressions'",
        "3 probe-eligible",
        "GHSA-active-1111",
        "GHSA-expired-3333",
    )


def test_neither_key_with_unclassifiable_toml_lists_entries_as_static(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
) -> None:
    """Entries without ``ignoreUntil`` never reach the probe, so list them."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-no-suppressions-meta.json",
        workspace / "osv-results.json",
    )
    _install(
        fixtures_dir,
        "security/osv-scanner-no-ignore-until.toml",
        workspace / ".osv-scanner.toml",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        "Status unavailable",
        "| `GHSA-xxxx-yyyy-zzzz` | ? | No fix available |",
    )
    assert_that(output).does_not_contain("No suppressions configured.")


def test_mixed_toml_lists_undated_entries_next_to_probe_table(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
) -> None:
    """Undated entries the probe never saw are kept when probe data exists."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-metadata-suppressions.json",
        workspace / "osv-results.json",
    )
    _install(
        fixtures_dir,
        "security/osv-scanner-mixed-dated-undated.toml",
        workspace / ".osv-scanner.toml",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        STALE_ROW,
        "Status unavailable",
        "| `GHSA-undated-4444` | ? | no expiry date |",
    )


def test_datetime_ignore_until_is_not_probe_eligible(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """lintro rejects TOML datetimes, so they must not trigger the failure."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-no-suppressions-meta.json",
        workspace / "osv-results.json",
    )
    (workspace / ".osv-scanner.toml").write_text(
        '[[IgnoredVulns]]\nid = "GHSA-datetime-5555"\n'
        'ignoreUntil = 2099-12-31T00:00:00Z\nreason = "timestamp"\n',
        encoding="utf-8",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains("Status unavailable", "`GHSA-datetime-5555`")
    assert_that(capsys.readouterr().err).is_empty()


@pytest.mark.parametrize(
    ("entries", "fragment"),
    [
        ([None], "entry 0 is not an object"),
        ([{"id": "GHSA-x", "status": "active"}, {"status": "stale"}], "no string 'id'"),
        ([{"id": "GHSA-x"}], "status None"),
        ([{"id": "GHSA-x", "status": "ignored"}], "status 'ignored'"),
    ],
    ids=["non-object", "missing-id", "missing-status", "unknown-status"],
)
def test_malformed_probe_entries_fail_loudly(
    formatter: ModuleType,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
    entries: list[object],
    fragment: str,
) -> None:
    """Probe lists that do not match lintro's entry shape are rejected."""
    json_path = workspace / "osv-results.json"
    json_path.write_text(
        json.dumps(
            {
                "results": [
                    {
                        "tool": "osv_scanner",
                        "issues_count": 0,
                        "success": True,
                        "metadata": {"suppressions": entries},
                    },
                ],
            },
        ),
        encoding="utf-8",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).is_none()
    assert_that(capsys.readouterr().err).contains(
        "malformed probe metadata",
        fragment,
    )


def test_vulnerability_table_renders_issue_rows(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
) -> None:
    """Reported issues render as table rows with the lockfile path."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-with-vuln.json",
        workspace / "osv-results.json",
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        "### 🚨 Vulnerability Report:",
        "| GHSA-xxxx-yyyy-zzzz in example-crate | `Cargo.lock` |",
    )


def test_main_exits_nonzero_when_status_unavailable(
    formatter: ModuleType,
    fixtures_dir: Path,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The CLI exit code surfaces the loud failure to run-lintro-audit.sh."""
    json_path = _install(
        fixtures_dir,
        "security/osv-results-no-suppressions-meta.json",
        workspace / "osv-results.json",
    )
    _install(
        fixtures_dir,
        "security/osv-scanner-active-stale-expired.toml",
        workspace / ".osv-scanner.toml",
    )
    monkeypatch.setattr("sys.argv", ["format-security-comment.py", str(json_path)])

    with pytest.raises(SystemExit) as excinfo:
        formatter.main()

    assert_that(excinfo.value.code).is_equal_to(1)
    captured = capsys.readouterr()
    assert_that(captured.out).is_empty()
    assert_that(captured.err).contains("Suppression status unavailable")
