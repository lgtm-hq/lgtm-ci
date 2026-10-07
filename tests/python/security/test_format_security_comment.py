# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/security/format-security-comment.py``.

Covers the lintro result schemas the script consumes: the current
``metadata.suppressions`` key, the legacy ``ai_metadata`` key (py-lintro
< 0.95.0), neither key present, and suppressions present or absent.

Fixtures ``formatter``, ``workspace`` and ``install_fixture`` come from
``tests/python/conftest.py``.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

RESULTS = "osv-results.json"
TOML = ".osv-scanner.toml"
METADATA_FIXTURE = "security/osv-results-metadata-suppressions.json"
NO_META_FIXTURE = "security/osv-results-no-suppressions-meta.json"
DATED_TOML_FIXTURE = "security/osv-scanner-active-stale-expired.toml"

STALE_ROW = "| `GHSA-stale-2222` | 2099-12-31 | :warning: **Stale — safe to remove** |"
EXPIRED_ROW = "| :warning: `GHSA-expired-3333` | **EXPIRED** 2020-01-01 |"
ACTIVE_ROW = "| `GHSA-active-1111` | 2099-12-31 | Active | still present |"
NO_SUPPRESSIONS = "No suppressions configured."

Installer = Callable[[str, str], Path]


def _write_result(workspace: Path, result: dict[str, object]) -> Path:
    """Write a one-result lintro report into the workspace.

    Args:
        workspace: Directory to write ``osv-results.json`` into.
        result: The ``osv_scanner`` result object without its ``tool`` key.

    Returns:
        The report path.
    """
    json_path = workspace / RESULTS
    json_path.write_text(
        json.dumps({"results": [{"tool": "osv_scanner", **result}]}),
        encoding="utf-8",
    )
    return json_path


@pytest.mark.parametrize(
    ("fixture", "expect_warning"),
    [
        (METADATA_FIXTURE, False),
        ("security/osv-results-legacy-ai-metadata.json", True),
    ],
    ids=["schema=metadata", "schema=legacy-ai_metadata"],
)
def test_probe_suppressions_render_status_table(
    formatter: ModuleType,
    install_fixture: Installer,
    capsys: pytest.CaptureFixture[str],
    fixture: str,
    expect_warning: bool,
) -> None:
    """Both schemas render the classified table; only legacy warns."""
    json_path = install_fixture(fixture, RESULTS)

    output = formatter.format_comment(str(json_path))

    assert_that(output).is_not_none()
    assert_that(output).contains(ACTIVE_ROW, STALE_ROW, EXPIRED_ROW)
    assert_that(output).does_not_contain(NO_SUPPRESSIONS)
    stderr = capsys.readouterr().err
    if expect_warning:
        assert_that(stderr).contains("legacy 'ai_metadata'", "lgtm-hq/lgtm-ci#825")
    else:
        assert_that(stderr).is_empty()


def test_metadata_key_wins_over_legacy_key(
    formatter: ModuleType,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """When both keys are present the current key is read and legacy ignored."""
    json_path = _write_result(
        workspace=workspace,
        result={
            "issues_count": 0,
            "success": True,
            "metadata": {"suppressions": [{"id": "GHSA-new", "status": "stale"}]},
            "ai_metadata": {
                "suppressions": [{"id": "GHSA-old", "status": "active"}],
            },
        },
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains("`GHSA-new`").does_not_contain("GHSA-old")
    assert_that(capsys.readouterr().err).is_empty()


def test_unusable_metadata_falls_back_to_legacy_with_warning(
    formatter: ModuleType,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A metadata object without a suppression list still honours legacy."""
    json_path = _write_result(
        workspace=workspace,
        result={
            "issues_count": 0,
            "success": True,
            "metadata": {"fixed_count": 0},
            "ai_metadata": {
                "suppressions": [{"id": "GHSA-old", "status": "active"}],
            },
        },
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains("| `GHSA-old` | ? | Active |  |")
    assert_that(capsys.readouterr().err).contains("legacy 'ai_metadata'")


@pytest.mark.parametrize(
    "result",
    [
        {},
        {"metadata": {"fixed_count": 0}},
        {"metadata": {"suppressions": "nope"}},
        {"metadata": None, "ai_metadata": []},
    ],
    ids=["no-key", "metadata-without-suppressions", "non-list", "non-object"],
)
def test_absent_probe_list_without_toml_reports_no_suppressions(
    formatter: ModuleType,
    workspace: Path,
    capsys: pytest.CaptureFixture[str],
    result: dict[str, object],
) -> None:
    """Absent or unusable probe metadata reads as 'probe did not run'."""
    json_path = _write_result(
        workspace=workspace,
        result={"issues_count": 0, "success": True, **result},
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(NO_SUPPRESSIONS)
    assert_that(capsys.readouterr().err).is_empty()


def test_empty_probe_list_reports_no_suppressions(
    formatter: ModuleType,
    workspace: Path,
) -> None:
    """Defensive: an empty list renders the empty message.

    lintro never emits an empty list (the key is omitted instead), so this
    only pins the behaviour for hand-written or future producers.
    """
    json_path = _write_result(
        workspace=workspace,
        result={"issues_count": 0, "success": True, "metadata": {"suppressions": []}},
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(NO_SUPPRESSIONS)


def test_clean_scan_without_probe_reports_no_suppressions(
    formatter: ModuleType,
    install_fixture: Installer,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """No probe metadata and no TOML is the legitimate nothing-to-classify case."""
    json_path = install_fixture("security/osv-results-clean.json", RESULTS)

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        "No security vulnerabilities found in dependencies.",
        NO_SUPPRESSIONS,
    )
    assert_that(capsys.readouterr().err).is_empty()


def test_neither_key_with_probe_eligible_toml_fails_loudly(
    formatter: ModuleType,
    install_fixture: Installer,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Missing probe metadata with classifiable TOML entries is an error."""
    json_path = install_fixture(NO_META_FIXTURE, RESULTS)
    install_fixture(DATED_TOML_FIXTURE, TOML)

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
        "Next steps",
    )


def test_scanner_error_keeps_diagnostic_when_probe_is_missing(
    formatter: ModuleType,
    workspace: Path,
    install_fixture: Installer,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A failed scan has no probe data; the scanner error must stay visible."""
    json_path = _write_result(
        workspace=workspace,
        result={
            "issues_count": 0,
            "success": False,
            "output": "OSV-Scanner timed out after 300s",
        },
    )
    install_fixture(DATED_TOML_FIXTURE, TOML)

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        "### ⚠️ Scanner Error:",
        "OSV-Scanner timed out after 300s",
        "_Suppression status unavailable: the scan failed",
    )
    assert_that(capsys.readouterr().err).is_empty()


def test_neither_key_with_unclassifiable_toml_lists_entries_as_static(
    formatter: ModuleType,
    install_fixture: Installer,
) -> None:
    """Entries without ``ignoreUntil`` never reach the probe, so list them."""
    json_path = install_fixture(NO_META_FIXTURE, RESULTS)
    install_fixture("security/osv-scanner-no-ignore-until.toml", TOML)

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        "Status unavailable",
        "| `GHSA-xxxx-yyyy-zzzz` | ? | No fix available |",
    )
    assert_that(output).does_not_contain(NO_SUPPRESSIONS)


def test_mixed_toml_lists_undated_entries_next_to_probe_table(
    formatter: ModuleType,
    install_fixture: Installer,
) -> None:
    """Undated entries the probe never saw are kept when probe data exists."""
    json_path = install_fixture(METADATA_FIXTURE, RESULTS)
    install_fixture("security/osv-scanner-mixed-dated-undated.toml", TOML)

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        STALE_ROW,
        "Status unavailable",
        "| `GHSA-undated-4444` | ? | no expiry date |",
    )


def test_datetime_ignore_until_is_not_probe_eligible(
    formatter: ModuleType,
    workspace: Path,
    install_fixture: Installer,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """lintro rejects TOML datetimes, so they must not trigger the failure."""
    json_path = install_fixture(NO_META_FIXTURE, RESULTS)
    (workspace / TOML).write_text(
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
    json_path = _write_result(
        workspace=workspace,
        result={
            "issues_count": 0,
            "success": True,
            "metadata": {"suppressions": entries},
        },
    )

    output = formatter.format_comment(str(json_path))

    assert_that(output).is_none()
    assert_that(capsys.readouterr().err).contains(
        "malformed probe metadata",
        fragment,
    )


def test_vulnerability_table_renders_issue_rows(
    formatter: ModuleType,
    install_fixture: Installer,
) -> None:
    """Reported issues render as table rows with the lockfile path."""
    json_path = install_fixture("security/osv-results-with-vuln.json", RESULTS)

    output = formatter.format_comment(str(json_path))

    assert_that(output).contains(
        "### 🚨 Vulnerability Report:",
        "| GHSA-xxxx-yyyy-zzzz in example-crate | `Cargo.lock` |",
    )


def test_main_prints_markdown_on_success(
    formatter: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The CLI writes the comment body to stdout and returns normally."""
    json_path = install_fixture(METADATA_FIXTURE, RESULTS)
    monkeypatch.setattr("sys.argv", ["format-security-comment.py", str(json_path)])

    formatter.main()

    captured = capsys.readouterr()
    assert_that(captured.out).contains("### 🔍 Checks Performed:", STALE_ROW)
    assert_that(captured.err).is_empty()


def test_main_exits_nonzero_when_status_unavailable(
    formatter: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The CLI exit code surfaces the loud failure to run-lintro-audit.sh."""
    json_path = install_fixture(NO_META_FIXTURE, RESULTS)
    install_fixture(DATED_TOML_FIXTURE, TOML)
    monkeypatch.setattr("sys.argv", ["format-security-comment.py", str(json_path)])

    with pytest.raises(SystemExit) as excinfo:
        formatter.main()

    assert_that(excinfo.value.code).is_equal_to(1)
    captured = capsys.readouterr()
    assert_that(captured.out).is_empty()
    assert_that(captured.err).contains("Suppression status unavailable")
