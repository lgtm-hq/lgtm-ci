# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/security/classify-suppressions.py``.

The classifier reads an osv-scanner probe on stdin and the suppressions in
``CONFIG_PATH`` (default ``.osv-scanner.toml``), and prints a JSON object
splitting the suppressed IDs into active, stale (vulnerability gone, safe to
remove), expired (timebox lapsed, a human re-evaluates) and not understood
(left alone). These tests cover the suppression file and classification;
probe parsing and the shell output are in ``test_classify_suppressions_io.py``.

Fixtures ``workspace`` and ``install_fixture`` come from
``tests/python/conftest.py``.
"""

from __future__ import annotations

import io
import json
import runpy
import sys
import time
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/security/classify-suppressions.py"
PROJECT_ROOT = Path(__file__).resolve().parents[3]
TOML = ".osv-scanner.toml"
NOW = datetime(2026, 6, 15, 12, 0, tzinfo=timezone.utc)
PLUS_TWO = timezone(timedelta(hours=2))
REASON_TWIN = "differs from 'reason' only by case"
CASE_TWIN = "key 'IgnoreUntil' differs from 'ignoreUntil'"
READ_AS_UNSET = "which osv-scanner reads as unset"
UNPRINTABLE = "its id has surrounding whitespace or a character that is not printable"
EMPTY: dict[str, Any] = {
    "active": [],
    "stale": [],
    "expired": [],
    "expired_until": {},
    "not_understood": [],
    "scan_checked": True,
    "held_back": [],
}

Installer = Callable[[str, str], Path]


@pytest.fixture(name="classifier", scope="module")
def fixture_classifier(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the classifier once per module."""
    return load_script(SCRIPT)


@pytest.fixture(autouse=True)
def _clean_environment(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Any:
    """Pin the clock and zone, give the probe an empty stderr, no arguments.

    ``run_main`` sets ``PROBE_EXIT`` to the status each probe implies; the
    scan checks themselves are tested in ``test_classify_suppressions_io.py``.
    ``CHECK_NOW`` is ``NOW`` and the zone is UTC unless a test says otherwise.
    """
    for name in ("CONFIG_PATH", "PROBE_EXIT"):
        monkeypatch.delenv(name, raising=False)
    stderr_file = tmp_path / "probe-stderr"
    stderr_file.write_text("", encoding="utf-8")
    monkeypatch.setenv("PROBE_STDERR_FILE", str(stderr_file))
    monkeypatch.setenv("CHECK_NOW", "2026-06-15T12:00:00Z")
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    monkeypatch.setattr(sys, "argv", ["classify-suppressions.py"])
    yield
    monkeypatch.undo()
    time.tzset()


def probe(*ids: str) -> str:
    """Return osv-scanner JSON reporting ``ids`` as present vulnerabilities.

    The shape follows osv-scanner 2.7.1: one package per ID, with the ID in
    ``vulnerabilities`` and in its group. No IDs is a clean scan.
    """
    packages = [
        {
            "package": {"name": "pkg", "version": "1.0.0", "ecosystem": "npm"},
            "vulnerabilities": [{"id": vuln_id}],
            "groups": [{"ids": [vuln_id], "aliases": [vuln_id], "max_severity": ""}],
        }
        for vuln_id in ids
    ]
    source = {"path": "/x/package-lock.json", "type": "lockfile"}
    results = [{"source": source, "packages": packages}] if packages else []
    return json.dumps({"results": results})


def run_main(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
) -> dict[str, Any]:
    """Run ``main`` with ``stdin`` and return the parsed JSON it prints."""
    expected = classifier.parse_probe(stdin).expected_exit
    monkeypatch.setenv("PROBE_EXIT", str(expected))
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    classifier.main()
    result: dict[str, Any] = json.loads(capsys.readouterr().out)
    return result


def entry(
    classifier: ModuleType,
    vuln_id: str,
    until: date | None = None,
    effective: date | None = None,
) -> Any:
    """Build a ``SuppressionEntry`` with an empty reason."""
    return classifier.SuppressionEntry(
        id=vuln_id,
        ignore_until=until,
        reason="",
        effective_until=effective,
    )


def write(path: Path, text: str) -> Path:
    """Write ``text`` to ``path`` as UTF-8 and return the path."""
    path.write_text(text, encoding="utf-8")
    return path


# --- main


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
            **EMPTY,
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
def test_missing_timebox_is_permanent(
    classifier: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Without a timebox an entry never expires."""
    install_fixture("security/osv-scanner-permanent.toml", TOML)

    result = run_main(classifier, monkeypatch, capsys, probe("GHSA-permanent-active"))

    assert_that(result["active"]).is_equal_to(["GHSA-permanent-active"])
    assert_that(result["stale"]).is_equal_to(["GHSA-permanent-stale"])
    assert_that(result["expired"]).is_empty()


@pytest.mark.usefixtures("workspace")
@pytest.mark.parametrize("stdin", ["", "  \n\t\n"])
def test_empty_probe_output_exits_1(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
) -> None:
    """No scan results means nothing can be classified: exit 1."""
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))

    with pytest.raises(SystemExit) as exc_info:
        classifier.main()

    captured = capsys.readouterr()
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(captured.out).is_empty()
    assert_that(captured.err).contains("osv-scanner produced no output")


@pytest.mark.usefixtures("workspace")
def test_no_config_file_means_no_suppressions(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A repository without ``.osv-scanner.toml`` classifies to empty lists."""
    result = run_main(classifier, monkeypatch, capsys, probe("GHSA-x"))

    assert_that(result).is_equal_to(EMPTY)


@pytest.mark.parametrize(
    ("content", "detail"),
    [
        (b"[[IgnoredVulns]\nid = 'x'\n", "cannot read suppression file"),
        (b'[[IgnoredVulns]]\nid = "\xff"\n', "can't decode byte 0xff"),
        (b"x = " + b"[" * 5000 + b"]" * 5000 + b"\n", "nested too deeply"),
        (b"x = " + b"9" * 5000 + b"\n", "Exceeds the limit"),
        (b"IgnoredVulns = 5\n", "IgnoredVulns must be an array of tables"),
        (b'IgnoredVulns = ["GHSA-1"]\n', "IgnoredVulns must be an array of tables"),
    ],
    ids=["bad-toml", "not-utf8", "deep", "huge-int", "integer", "strings"],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_unusable_config_fails_with_one_line(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    content: bytes,
    detail: str,
) -> None:
    """A file osv-scanner would refuse fails the run before anything prints."""
    (workspace / TOML).write_bytes(content)
    monkeypatch.setattr(sys, "stdin", io.StringIO(probe()))

    with pytest.raises(SystemExit) as exc_info:
        classifier.main()

    captured = capsys.readouterr()
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(captured.out).is_empty()
    assert_that(captured.err.splitlines()).is_length(1)
    assert_that(captured.err).starts_with("ERROR: ").contains(TOML, detail)


def test_runs_as_a_script(
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Run as ``__main__``, the classifier prints the JSON object."""
    write(workspace / TOML, '[[IgnoredVulns]]\nid = "A"\n')
    monkeypatch.setattr(sys, "stdin", io.StringIO(probe("A")))
    monkeypatch.setenv("PROBE_EXIT", "1")

    runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(json.loads(capsys.readouterr().out)["active"]).is_equal_to(["A"])


def test_a_mixed_case_id_key_keeps_the_whole_block(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``ID`` is ``id`` to osv-scanner, so neither ID may be called stale."""
    write(workspace / TOML, '[[IgnoredVulns]]\nid = "STALE"\nID = "CVE-2018-18074"\n')

    result = run_main(classifier, monkeypatch, capsys, probe("CVE-2018-18074"))

    description = "entry 1, id 'STALE': key 'ID' differs from 'id' only by case"
    assert_that(result).is_equal_to(
        {
            **EMPTY,
            "not_understood": [description],
            "held_back": ["CVE-2018-18074", "STALE"],
        },
    )


@pytest.mark.parametrize("key", ["effectiveUntil", "ignoreUntil"])
def test_a_lapsed_timebox_is_expired_not_stale(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    key: str,
) -> None:
    """``effectiveUntil`` counts like ``ignoreUntil``: a lapse is never stale."""
    write(workspace / TOML, f'[[IgnoredVulns]]\nid = "GHSA-x"\n{key} = 2020-01-01\n')

    result = run_main(classifier, monkeypatch, capsys, probe())

    assert_that(result).is_equal_to(
        {**EMPTY, "expired": ["GHSA-x"], "expired_until": {"GHSA-x": "2020-01-01"}},
    )


@pytest.mark.parametrize(
    ("probe_ids", "expected"),
    [(set(), EMPTY), ({"GHSA-live"}, {**EMPTY, "active": ["GHSA-live"]})],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_a_whitespace_twin_never_makes_its_id_stale(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    probe_ids: set[str],
    expected: dict[str, Any],
) -> None:
    """``" GHSA-live"`` beside ``GHSA-live``: neither is ever reported stale."""
    write(
        workspace / TOML,
        '[[IgnoredVulns]]\nid = "GHSA-live"\n\n[[IgnoredVulns]]\nid = " GHSA-live"\n',
    )

    result = run_main(classifier, monkeypatch, capsys, probe(*probe_ids))

    twin = f"entry 2, id '\" GHSA-live\"': {UNPRINTABLE}"
    held = [" GHSA-live", "GHSA-live"]
    assert_that(result).is_equal_to(
        {**expected, "not_understood": [twin], "held_back": held},
    )


# --- read_suppressions


def test_parse_keeps_understood_entries_in_order(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """IDs, timeboxes and reasons are read; a missing reason is empty."""
    path = write(
        tmp_path / TOML,
        '[[IgnoredVulns]]\nid = "B"\nignoreUntil = 2027-01-31\nreason = "rü"\n\n'
        '[[IgnoredVulns]]\nid = "A"\neffectiveUntil = 2027-02-01T10:00:00Z\n',
    )

    entries = classifier.parse_suppressions(path)

    assert_that(entries).is_equal_to(
        [
            classifier.SuppressionEntry(
                id="B",
                ignore_until=date(2027, 1, 31),
                reason="rü",
            ),
            entry(
                classifier,
                "A",
                effective=datetime(2027, 2, 1, 10, 0, tzinfo=timezone.utc),
            ),
        ],
    )


@pytest.mark.parametrize(
    ("body", "description", "held"),
    [
        (
            'id = "STALE"\nID = "CVE-1"',
            "entry 1, id 'STALE': key 'ID' differs from 'id' only by case",
            {"STALE", "CVE-1"},
        ),
        (
            'id = "A"\nIgnoreUntil = 2020-01-01',
            f"entry 1, id 'A': {CASE_TWIN} only by case",
            {"A"},
        ),
        (
            'id = "A"\nreason = ["not a string"]',
            "entry 1, id 'A': reason is list, not a string",
            {"A"},
        ),
        ('id = "A"\nnote = "x"', "entry 1, id 'A': unknown key 'note'", {"A"}),
        (
            'id = "A"\n"rea\u017fon" = "x"',
            "entry 1, id 'A': key '\"rea\\u017fon\"' " + REASON_TWIN,
            {"A"},
        ),
        (
            'id = "A"\n"\u212a" = 1',
            "entry 1, id 'A': unknown key '\"\\u212a\"'",
            {"A"},
        ),
        ('id = "A"\n"id " = "B"', "entry 1, id 'A': unknown key '\"id \"'", {"A"}),
        (
            'ID = "A"',
            "entry 1: key 'ID' differs from 'id' only by case; it has no id",
            {"A"},
        ),
        ("id = 7", "entry 1: id is int, not a string", set()),
        ('id = ""', "entry 1, id '\"\"': it has no id", {""}),
        ('reason = "no id"', "entry 1: it has no id", set()),
        (
            'id = "A"\nignoreUntil = "2027-01-31"',
            "entry 1, id 'A': ignoreUntil is str, not a date or date-time",
            {"A"},
        ),
        (
            'id = "A"\neffectiveUntil = 10:30:00',
            "entry 1, id 'A': effectiveUntil is time, not a date or date-time",
            {"A"},
        ),
        (
            'id = "A"\nignoreUntil = 0001-01-01',
            f"entry 1, id 'A': ignoreUntil is in year 1, {READ_AS_UNSET}",
            {"A"},
        ),
        ('id = " A\\t"', f"entry 1, id '\" A\\t\"': {UNPRINTABLE}", {" A\t", "A"}),
        (
            'id = "GHSA-\\u200bx"',
            f"entry 1, id '\"GHSA-\\u200bx\"': {UNPRINTABLE}",
            {"GHSA-\u200bx", "GHSA-x"},
        ),
    ],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_entries_not_understood_are_held_back(
    classifier: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    body: str,
    description: str,
    held: set[str],
) -> None:
    """Any key, type or ID form osv-scanner reads differently is left alone."""
    path = write(tmp_path / TOML, f"[[IgnoredVulns]]\n{body}\n")

    suppressions = classifier.read_suppressions(path)

    assert_that(suppressions.entries).is_empty()
    assert_that(suppressions.held_back).is_equal_to(held)
    assert_that(suppressions.not_understood).is_equal_to([description])
    assert_that(capsys.readouterr().err).is_equal_to(
        f"WARNING: left alone, not understood: {description}\n",
    )


@pytest.mark.parametrize(
    ("twin", "held"),
    [
        ('[[ignoredvulns]]\nid = "B"\n', {"A", "B"}),
        ("IGNOREDVULNS = 5\n", {"A"}),
        ('[["IgnoredVuln\u017f"]]\nid = "B"\n', {"A", "B"}),
        ('ignoredVulns = ["B", {ID = "C"}]\n', {"A", "C"}),
    ],
)
def test_a_case_twin_of_the_table_holds_back_every_id(
    classifier: ModuleType,
    tmp_path: Path,
    twin: str,
    held: set[str],
) -> None:
    """osv-scanner might read either table, so nothing is reported stale."""
    path = write(tmp_path / TOML, f'{twin}[[IgnoredVulns]]\nid = "A"\n')

    suppressions = classifier.read_suppressions(path)

    assert_that([item.id for item in suppressions.entries]).is_equal_to(["A"])
    assert_that(suppressions.held_back).is_equal_to(held)
    assert_that(suppressions.not_understood[0]).ends_with(
        "differs from 'IgnoredVulns' only by case; no entry is reported stale",
    )


@pytest.mark.parametrize(
    ("name", "key", "same"),
    [
        ("id", "ID", True),
        ("IgnoredVulns", "IgnoredVuln\u017f", True),
        ("k", "\u212a", True),
        ("reason", "REA\u017fON", True),
        ("reason", "reasons", False),
        ("id", "\u0131d", False),
    ],
)
def test_same_name_folds_like_go(
    classifier: ModuleType,
    name: str,
    key: str,
    same: bool,
) -> None:
    """Long s and the Kelvin sign fold as in Go's ``strings.EqualFold``."""
    assert_that(classifier.same_name(name, key)).is_equal_to(same)


def test_parse_ignores_other_sections(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """A config with only ``[PackageOverrides]`` has no suppressions."""
    path = write(tmp_path / TOML, '[[PackageOverrides]]\nname = "x"\nignore = true\n')

    assert_that(classifier.parse_suppressions(path)).is_empty()


# --- classify


@pytest.mark.parametrize(
    ("until", "category"),
    [
        (date(2026, 6, 14), "expired"),
        (date(2026, 6, 15), "expired"),
        (date(2026, 6, 16), "active"),
        (None, "active"),
        (NOW, "expired"),
        (NOW + timedelta(seconds=1), "active"),
        (datetime(2026, 6, 15, 11, 59), "expired"),
        (datetime(2026, 6, 15, 12, 1), "active"),
        (datetime(2026, 6, 15, 13, 0, tzinfo=PLUS_TWO), "expired"),
        (datetime(2026, 6, 15, 15, 0, tzinfo=PLUS_TWO), "active"),
    ],
)
def test_expiry_boundary_matches_osv_scanner(
    classifier: ModuleType,
    until: date | None,
    category: str,
) -> None:
    """An entry stops at the instant its timebox names (``time.After``).

    A date means midnight at its start, and a date-time without an offset is
    read in the current offset, as osv-scanner's TOML decoder does.
    """
    result = classifier.classify([entry(classifier, "A", until)], {"A"}, now=NOW)

    assert_that(getattr(result, category)).is_equal_to(["A"])


def test_a_local_date_time_is_read_in_the_given_offset(
    classifier: ModuleType,
) -> None:
    """At 12:00+02:00, a local 11:00 has passed; read as UTC it has not."""
    now = datetime(2026, 6, 15, 12, 0, tzinfo=PLUS_TWO)
    entries = [entry(classifier, "A", datetime(2026, 6, 15, 11, 0))]

    result = classifier.classify(entries, {"A"}, now=now)

    assert_that(result.expired).is_equal_to(["A"])


@pytest.fixture(name="runner_at_plus_two")
def fixture_runner_at_plus_two(monkeypatch: pytest.MonkeyPatch) -> Any:
    """Run with the machine's time zone two hours ahead of UTC."""
    monkeypatch.setenv("TZ", "Etc/GMT-2")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


@pytest.mark.usefixtures("runner_at_plus_two")
def test_a_local_date_time_uses_the_runner_offset(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """With TZ two hours ahead, a local 13:00 has passed at 12:00 UTC."""
    write(
        workspace / TOML,
        '[[IgnoredVulns]]\nid = "A"\neffectiveUntil = 2026-06-15T13:00:00\n',
    )

    result = run_main(classifier, monkeypatch, capsys, probe())

    assert_that(result["expired"]).is_equal_to(["A"])


@pytest.mark.parametrize(
    ("check_now", "expired"),
    [("2026-06-15T23:59:59Z", []), ("2026-06-16T00:00:00Z", ["A"])],
)
@pytest.mark.parametrize("argv", [[], ["--expired"]])
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_both_modes_decide_expiry_at_the_given_instant(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    check_now: str,
    expired: list[str],
    argv: list[str],
) -> None:
    """``CHECK_NOW``, not the system clock, decides expiry in both passes."""
    write(workspace / TOML, '[[IgnoredVulns]]\nid = "A"\neffectiveUntil = 2026-06-16\n')
    monkeypatch.setenv("CHECK_NOW", check_now)
    monkeypatch.setattr(sys, "argv", ["classify-suppressions.py", *argv])

    result = run_main(classifier, monkeypatch, capsys, probe("A"))

    assert_that(result["expired"]).is_equal_to(expired)


@pytest.mark.parametrize(
    "value",
    [
        None,
        "",
        "2026-06-15 12:00:00",
        "2026-06-15T12:00:00+02:00",
        "2026-06-15T12:00:00.5Z",
        "2026-13-01T00:00:00Z",
        "now",
    ],
)
@pytest.mark.parametrize("argv", [[], ["--expired"]])
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_a_missing_or_malformed_instant_fails(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    value: str | None,
    argv: list[str],
) -> None:
    """Each mode that decides expiry needs one well-formed UTC instant."""
    write(workspace / TOML, '[[IgnoredVulns]]\nid = "A"\n')
    if value is None:
        monkeypatch.delenv("CHECK_NOW")
    else:
        monkeypatch.setenv("CHECK_NOW", value)
    monkeypatch.setattr(sys, "argv", ["classify-suppressions.py", *argv])
    monkeypatch.setenv("PROBE_EXIT", "1")
    monkeypatch.setattr(sys, "stdin", io.StringIO(probe("A")))

    with pytest.raises(SystemExit) as exc_info:
        classifier.main()

    err = capsys.readouterr().err
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(err.splitlines()).is_length(1)
    assert_that(err).starts_with(
        "ERROR: CHECK_NOW must be one instant as YYYY-MM-DDTHH:MM:SSZ, not ",
    ).ends_with(": every pass decides expiry at that instant\n")


@pytest.fixture(name="new_york")
def fixture_new_york(monkeypatch: pytest.MonkeyPatch) -> Any:
    """Run in a zone with daylight saving (America/New_York)."""
    monkeypatch.setenv("TZ", "America/New_York")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


EDT = timezone(timedelta(hours=-4))
EST = timezone(timedelta(hours=-5))


@pytest.mark.usefixtures("new_york")
@pytest.mark.parametrize(
    ("wall", "now", "lapse"),
    [
        # 01:30 happens twice on 2026-11-01 (EDT, then EST): the earlier one.
        (
            datetime(2026, 11, 1, 1, 30),
            datetime(2026, 11, 1, 1, 15, tzinfo=EDT),
            datetime(2026, 11, 1, 5, 30, tzinfo=timezone.utc),
        ),
        # 02:30 never happens on 2026-03-08 (EST jumps to EDT): the earlier one.
        (
            datetime(2026, 3, 8, 2, 30),
            datetime(2026, 3, 8, 1, 0, tzinfo=EST),
            datetime(2026, 3, 8, 6, 30, tzinfo=timezone.utc),
        ),
        # An ordinary time: one reading.
        (
            datetime(2026, 6, 15, 9, 0),
            datetime(2026, 6, 15, 8, 0, tzinfo=EDT),
            datetime(2026, 6, 15, 13, 0, tzinfo=timezone.utc),
        ),
    ],
    ids=["fall-back", "spring-forward", "ordinary"],
)
def test_a_local_time_resolves_to_its_earliest_reading(
    classifier: ModuleType,
    wall: datetime,
    now: datetime,
    lapse: datetime,
) -> None:
    """Ambiguous and skipped local times count as expired at the earliest."""
    entries = [entry(classifier, "A", None, wall)]

    result = classifier.classify(entries, {"A"}, now=lapse)

    assert_that(result.expired).is_equal_to(["A"])
    assert_that(classifier.classify(entries, {"A"}, now=now).expired).is_empty()


@pytest.mark.usefixtures("new_york")
def test_an_entry_expired_before_the_fall_back_stays_expired_after_it(
    classifier: ModuleType,
) -> None:
    """At 01:45 EDT and again at 01:15 EST, a local 01:30 entry is expired.

    Read with only the offset of the moment, the second instant would see it
    in effect again and could report it stale.
    """
    entries = [entry(classifier, "A", None, datetime(2026, 11, 1, 1, 30))]

    for now in (
        datetime(2026, 11, 1, 1, 45, tzinfo=EDT),
        datetime(2026, 11, 1, 1, 15, tzinfo=EST),
    ):
        assert_that(classifier.classify(entries, set(), now=now).expired).is_equal_to(
            ["A"],
        )


def test_a_reading_past_the_end_of_the_date_range_is_left_out(
    classifier: ModuleType,
) -> None:
    """At 9999-12-31 the zone readings overflow; the offset reading stands."""
    entries = [entry(classifier, "A", date(9999, 12, 31))]

    result = classifier.classify(entries, {"A"}, now=NOW)

    assert_that(result.active).is_equal_to(["A"])


@pytest.mark.parametrize(
    ("ignore", "effective", "category"),
    [
        (date(2099, 1, 1), date(2020, 1, 1), "expired"),
        (date(2020, 1, 1), date(2099, 1, 1), "active"),
        (None, date(2020, 1, 1), "expired"),
    ],
)
def test_effective_until_wins_over_ignore_until(
    classifier: ModuleType,
    ignore: date | None,
    effective: date | None,
    category: str,
) -> None:
    """osv-scanner uses ``effectiveUntil`` and falls back to ``ignoreUntil``."""
    entries = [entry(classifier, "A", ignore, effective)]

    result = classifier.classify(entries, {"A"}, now=NOW)

    assert_that(getattr(result, category)).is_equal_to(["A"])


def test_expired_wins_over_present_or_absent(classifier: ModuleType) -> None:
    """A lapsed timebox is flagged even when the vulnerability is gone."""
    lapsed = date(2026, 1, 1)
    entries = [entry(classifier, "PRESENT", lapsed), entry(classifier, "GONE", lapsed)]

    result = classifier.classify(entries, {"PRESENT"}, now=NOW)

    assert_that(result.expired).is_equal_to(["PRESENT", "GONE"])
    assert_that(result.expired_until).is_equal_to(
        {"PRESENT": "2026-01-01", "GONE": "2026-01-01"},
    )
    assert_that(result.active + result.stale).is_empty()


def test_classify_keeps_entry_order(classifier: ModuleType) -> None:
    """Each list keeps the order of the suppression file."""
    entries = [entry(classifier, vuln_id) for vuln_id in ("C", "A", "D", "B")]

    result = classifier.classify(entries, {"D", "C"}, now=NOW)

    assert_that(result.active).is_equal_to(["C", "D"])
    assert_that(result.stale).is_equal_to(["A", "B"])


@pytest.mark.parametrize(
    ("probe_ids", "category"),
    [(set(), "stale"), ({"DUP"}, "active")],
)
def test_duplicate_id_is_reported_once(
    classifier: ModuleType,
    capsys: pytest.CaptureFixture[str],
    probe_ids: set[str],
    category: str,
) -> None:
    """An ID listed twice appears once, in its first position, with a warning."""
    entries = [
        entry(classifier, "DUP"),
        entry(classifier, "OTHER", date(2099, 1, 1)),
        entry(classifier, "DUP", date(2099, 1, 1)),
    ]

    result = classifier.classify(entries, probe_ids | {"OTHER"}, now=NOW)

    assert_that(getattr(result, category)[0]).is_equal_to("DUP")
    assert_that(result.active + result.stale).is_length(2)
    assert_that(capsys.readouterr().err).is_equal_to(
        "WARNING: 'DUP' is listed more than once; "
        "reporting it once under its strictest reading\n",
    )


@pytest.mark.parametrize("probe_ids", [set(), {"DUP"}])
def test_duplicate_with_an_expired_copy_is_expired(
    classifier: ModuleType,
    probe_ids: set[str],
) -> None:
    """One lapsed copy flags the ID as expired, with the earliest lapse."""
    entries = [
        entry(classifier, "DUP"),
        entry(classifier, "DUP", date(2026, 3, 1)),
        entry(classifier, "DUP", datetime(2026, 1, 1, 6, 0, tzinfo=timezone.utc)),
        entry(classifier, "DUP", None, date(2026, 2, 1)),
    ]

    result = classifier.classify(entries, probe_ids, now=NOW)

    assert_that(result.expired).is_equal_to(["DUP"])
    assert_that(result.expired_until).is_equal_to(
        {"DUP": "2026-01-01T06:00:00+00:00"},
    )
    assert_that(result.active + result.stale).is_empty()


@pytest.mark.parametrize(
    ("until", "probe_ids", "category"),
    [
        (None, set(), None),
        (None, {"A"}, "active"),
        (date(2026, 1, 1), set(), "expired"),
    ],
)
def test_unclassified_id_is_never_stale(
    classifier: ModuleType,
    capsys: pytest.CaptureFixture[str],
    until: date | None,
    probe_ids: set[str],
    category: str | None,
) -> None:
    """Only the stale outcome is withheld; active and expired still report."""
    result = classifier.classify(
        [entry(classifier, "A", until)],
        probe_ids,
        now=NOW,
        unclassified={"A"},
    )

    assert_that(result.stale).is_empty()
    reported = [name for name in ("active", "expired") if getattr(result, name)]
    assert_that(reported).is_equal_to([category] if category else [])
    warning = (
        "WARNING: not reporting 'A' as stale: an entry that might carry this id "
        "is not understood\n"
    )
    assert_that(capsys.readouterr().err).is_equal_to(
        warning if category is None else "",
    )


def test_classify_with_no_entries(classifier: ModuleType) -> None:
    """No suppressions classify to empty lists whatever the probe holds."""
    result = classifier.classify([], {"A"}, now=NOW, not_understood=["entry 1: x"])

    assert_that(result).is_equal_to(
        classifier.Classification(
            active=[],
            stale=[],
            expired=[],
            expired_until={},
            not_understood=["entry 1: x"],
        ),
    )


def test_classify_defaults_to_now(classifier: ModuleType) -> None:
    """Without ``now`` the current time decides expiry."""
    entries = [
        entry(classifier, "PAST", date(2000, 1, 1)),
        entry(classifier, "FUTURE", date(9999, 12, 31)),
    ]

    result = classifier.classify(entries, {"FUTURE"})

    assert_that(result.expired).is_equal_to(["PAST"])
    assert_that(result.active).is_equal_to(["FUTURE"])
