# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/security/classify-suppressions.py``.

The classifier reads an osv-scanner probe on stdin and the suppressions in
``CONFIG_PATH`` (default ``.osv-scanner.toml``), and prints a JSON object
splitting the suppressed IDs into active, stale (vulnerability gone, safe to
remove) and expired (timebox lapsed, a human re-evaluates).

Fixtures ``workspace`` and ``install_fixture`` come from
``tests/python/conftest.py``.
"""

from __future__ import annotations

import io
import json
import runpy
import sys
import tomllib
from collections.abc import Callable
from datetime import date
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/security/classify-suppressions.py"
PROJECT_ROOT = Path(__file__).resolve().parents[3]
TOML = ".osv-scanner.toml"
TODAY = date(2026, 6, 15)

Installer = Callable[[str, str], Path]


@pytest.fixture(name="classifier", scope="module")
def fixture_classifier(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the classifier once per module."""
    return load_script(SCRIPT)


@pytest.fixture(autouse=True)
def _no_inherited_config_path(monkeypatch: pytest.MonkeyPatch) -> None:
    """Drop a ``CONFIG_PATH`` from the developer's environment.

    The script reads it, so an inherited value would replace each test's own
    suppression file. The override test sets it explicitly.
    """
    monkeypatch.delenv("CONFIG_PATH", raising=False)


def probe(*ids: str) -> str:
    """Return osv-scanner JSON reporting ``ids`` as present vulnerabilities."""
    vulns = [{"id": vuln_id} for vuln_id in ids]
    return json.dumps({"results": [{"packages": [{"vulnerabilities": vulns}]}]})


def run_main(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
) -> dict[str, Any]:
    """Run ``main`` with ``stdin`` and return the parsed JSON it prints.

    Args:
        classifier: The loaded script module.
        monkeypatch: Fixture used to replace ``sys.stdin``.
        capsys: Fixture capturing the printed JSON.
        stdin: The probe output fed to the script.

    Returns:
        The decoded JSON object.
    """
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    classifier.main()
    result: dict[str, Any] = json.loads(capsys.readouterr().out)
    return result


def entry(
    classifier: ModuleType,
    vuln_id: str,
    until: date | None = None,
) -> Any:
    """Build a ``SuppressionEntry`` with an empty reason."""
    return classifier.SuppressionEntry(id=vuln_id, ignore_until=until, reason="")


# --- main: ported from tests/bats/unit/security/test_classify_suppressions.bats


@pytest.mark.usefixtures("workspace")
def test_classifies_active_stale_and_expired(
    classifier: ModuleType,
    install_fixture: Installer,
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Each fixture entry lands in its category, expired with its date."""
    install_fixture("security/osv-scanner-active-stale-expired.toml", TOML)
    stdin = (fixtures_dir / "security" / "probe-active-1111.json").read_text()

    result = run_main(classifier, monkeypatch, capsys, stdin)

    assert_that(result).is_equal_to(
        {
            "active": ["GHSA-active-1111"],
            "stale": ["GHSA-stale-2222"],
            "expired": ["GHSA-expired-3333"],
            "expired_until": {"GHSA-expired-3333": "2020-01-01"},
        },
    )


def test_honors_config_path(
    classifier: ModuleType,
    install_fixture: Installer,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``CONFIG_PATH`` replaces the default ``.osv-scanner.toml``."""
    (workspace / "config").mkdir()
    install_fixture("security/osv-scanner-custom-path.toml", "config/custom.toml")
    monkeypatch.setenv("CONFIG_PATH", "config/custom.toml")

    result = run_main(classifier, monkeypatch, capsys, probe("CVE-2024-00001"))

    assert_that(result["active"]).is_equal_to(["CVE-2024-00001"])


@pytest.mark.usefixtures("workspace")
def test_missing_ignore_until_is_permanent(
    classifier: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Without ``ignoreUntil`` an entry never expires."""
    install_fixture("security/osv-scanner-permanent.toml", TOML)

    result = run_main(classifier, monkeypatch, capsys, probe("GHSA-permanent-active"))

    assert_that(result["active"]).is_equal_to(["GHSA-permanent-active"])
    assert_that(result["stale"]).is_equal_to(["GHSA-permanent-stale"])
    assert_that(result["expired"]).is_empty()
    assert_that(result["expired_until"]).is_empty()


@pytest.mark.usefixtures("workspace")
@pytest.mark.parametrize("stdin", ["", "  \n\t\n"])
def test_empty_probe_output_exits_1(
    classifier: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
) -> None:
    """No scan results means nothing can be classified: exit 1."""
    install_fixture("security/osv-scanner-probe-missing.toml", TOML)
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))

    with pytest.raises(SystemExit) as exc_info:
        classifier.main()

    captured = capsys.readouterr()
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(captured.out).is_empty()
    assert_that(captured.err).contains("osv-scanner produced no output")


# --- main: beyond the bats suite


@pytest.mark.usefixtures("workspace")
def test_malformed_probe_json_exits_1(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Probe output that is not JSON is an error, not an empty scan."""
    monkeypatch.setattr(sys, "stdin", io.StringIO("{not json"))

    with pytest.raises(SystemExit) as exc_info:
        classifier.main()

    captured = capsys.readouterr()
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(captured.out).is_empty()
    assert_that(captured.err).contains("failed to parse osv-scanner JSON output")


@pytest.mark.usefixtures("workspace")
def test_no_config_file_means_no_suppressions(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A repository without ``.osv-scanner.toml`` classifies to empty lists."""
    result = run_main(classifier, monkeypatch, capsys, probe("GHSA-x"))

    assert_that(result).is_equal_to(
        {"active": [], "stale": [], "expired": [], "expired_until": {}},
    )


def test_malformed_config_fails(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Broken suppression TOML fails the run before anything is printed."""
    (workspace / TOML).write_text("[[IgnoredVulns]\nid = 'x'\n", encoding="utf-8")
    monkeypatch.setattr(sys, "stdin", io.StringIO(probe()))

    with pytest.raises(tomllib.TOMLDecodeError):
        classifier.main()

    assert_that(capsys.readouterr().out).is_empty()


def test_runs_as_a_script(
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Run as ``__main__``, the classifier prints the JSON object."""
    (workspace / TOML).write_text('[[IgnoredVulns]]\nid = "A"\n', encoding="utf-8")
    monkeypatch.setattr(sys, "stdin", io.StringIO(probe("A")))

    runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(json.loads(capsys.readouterr().out)["active"]).is_equal_to(["A"])


# --- parse_suppressions


def test_parse_keeps_valid_entries_in_order(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """IDs, dates and reasons are read; a missing reason is empty."""
    path = tmp_path / TOML
    path.write_text(
        '[[IgnoredVulns]]\nid = "B"\nignoreUntil = 2027-01-31\nreason = "rü"\n\n'
        '[[IgnoredVulns]]\nid = "A"\n',
        encoding="utf-8",
    )

    entries = classifier.parse_suppressions(path)

    assert_that(entries).is_equal_to(
        [
            classifier.SuppressionEntry(
                id="B",
                ignore_until=date(2027, 1, 31),
                reason="rü",
            ),
            classifier.SuppressionEntry(id="A", ignore_until=None, reason=""),
        ],
    )


def test_parse_skips_entries_without_a_usable_id(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """Non-table items and missing, empty or non-string IDs are dropped."""
    path = tmp_path / TOML
    path.write_text(
        "IgnoredVulns = [\n"
        '  "GHSA-bare",\n  {reason = "no id"},\n  {id = ""},\n'
        '  {id = 7},\n  {id = "KEEP"},\n]\n',
        encoding="utf-8",
    )

    ids = [item.id for item in classifier.parse_suppressions(path)]

    assert_that(ids).is_equal_to(["KEEP"])


@pytest.mark.parametrize(
    ("value", "warning"),
    [
        ("2027-01-31T00:00:00", "must be a date, not datetime"),
        ("2027-01-31 10:00:00Z", "must be a date, not datetime"),
        ('"2027-01-31"', "unsupported type str"),
        ("10:30:00", "unsupported type time"),
        ("20270131", "unsupported type int"),
    ],
)
def test_parse_skips_ignore_until_that_is_not_a_date(
    classifier: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    value: str,
    warning: str,
) -> None:
    """A non-date timebox skips the entry with a warning naming it."""
    path = tmp_path / TOML
    path.write_text(
        f'[[IgnoredVulns]]\nid = "BAD"\nignoreUntil = {value}\n'
        + '[[IgnoredVulns]]\nid = "GOOD"\n',
        encoding="utf-8",
    )

    ids = [item.id for item in classifier.parse_suppressions(path)]

    assert_that(ids).is_equal_to(["GOOD"])
    err = capsys.readouterr().err
    assert_that(err).starts_with("WARNING: skipping 'BAD'").contains(warning)


def test_parse_ignores_other_sections(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """A config with only ``[PackageOverrides]`` has no suppressions."""
    path = tmp_path / TOML
    path.write_text('[[PackageOverrides]]\nname = "x"\nignore = true\n')

    assert_that(classifier.parse_suppressions(path)).is_empty()


# --- parse_probe_vuln_ids


def test_probe_ids_come_from_vulnerabilities_and_groups(
    classifier: ModuleType,
) -> None:
    """Both vulnerability IDs and group aliases count as present."""
    output = json.dumps(
        {
            "results": [
                {
                    "packages": [
                        {
                            "vulnerabilities": [{"id": "GHSA-1"}, {"id": ""}, {}],
                            "groups": [{"ids": ["GHSA-1", "CVE-2"]}, {}],
                        },
                        {"vulnerabilities": [{"id": 3}]},
                        {},
                    ],
                },
                {},
            ],
        },
    )

    ids = classifier.parse_probe_vuln_ids(output)

    assert_that(ids).is_equal_to({"GHSA-1", "CVE-2", "3"})


@pytest.mark.parametrize("output", ["{}", '{"results": []}'])
def test_probe_without_results_has_no_ids(
    classifier: ModuleType,
    output: str,
) -> None:
    """A clean scan reports no IDs, so every suppression is stale."""
    assert_that(classifier.parse_probe_vuln_ids(output)).is_empty()


# --- classify


@pytest.mark.parametrize(
    ("until", "category"),
    [
        (date(2026, 6, 14), "expired"),
        (date(2026, 6, 15), "active"),
        (date(2026, 6, 16), "active"),
        (None, "active"),
    ],
)
def test_expiry_boundary(
    classifier: ModuleType,
    until: date | None,
    category: str,
) -> None:
    """The timebox includes its own date; it expires the day after."""
    result = classifier.classify([entry(classifier, "A", until)], {"A"}, today=TODAY)

    assert_that(getattr(result, category)).is_equal_to(["A"])


def test_expired_wins_over_present_or_absent(classifier: ModuleType) -> None:
    """A lapsed timebox is flagged even when the vulnerability is gone."""
    lapsed = date(2026, 1, 1)
    entries = [entry(classifier, "PRESENT", lapsed), entry(classifier, "GONE", lapsed)]

    result = classifier.classify(entries, {"PRESENT"}, today=TODAY)

    assert_that(result.expired).is_equal_to(["PRESENT", "GONE"])
    assert_that(result.expired_until).is_equal_to(
        {"PRESENT": "2026-01-01", "GONE": "2026-01-01"},
    )
    assert_that(result.active).is_empty()
    assert_that(result.stale).is_empty()


def test_classify_keeps_entry_order(classifier: ModuleType) -> None:
    """Each list keeps the order of the suppression file."""
    entries = [entry(classifier, vuln_id) for vuln_id in ("C", "A", "D", "B")]

    result = classifier.classify(entries, {"D", "C"}, today=TODAY)

    assert_that(result.active).is_equal_to(["C", "D"])
    assert_that(result.stale).is_equal_to(["A", "B"])


def test_classify_with_no_entries(classifier: ModuleType) -> None:
    """No suppressions classify to empty lists whatever the probe holds."""
    result = classifier.classify([], {"A"}, today=TODAY)

    assert_that(result).is_equal_to(
        classifier.Classification(active=[], stale=[], expired=[], expired_until={}),
    )


def test_classify_defaults_to_today(classifier: ModuleType) -> None:
    """Without ``today`` the current date decides expiry."""
    entries = [
        entry(classifier, "PAST", date(2000, 1, 1)),
        entry(classifier, "FUTURE", date(9999, 12, 31)),
    ]

    result = classifier.classify(entries, {"FUTURE"})

    assert_that(result.expired).is_equal_to(["PAST"])
    assert_that(result.active).is_equal_to(["FUTURE"])
