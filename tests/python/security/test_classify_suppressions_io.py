# SPDX-License-Identifier: MIT
"""Probe parsing and shell output of ``scripts/ci/security/classify-suppressions.py``.

The probe must have the shape osv-scanner 2.x writes (checked against
``pkg/models/results.go``, ``pkg/osvscanner/filter.go`` and the JSON
snapshots of v2.7.1); anything else is an error, never a clean scan. Every
vulnerability ID and alias counts as present, because osv-scanner matches a
suppression against every alias of a group. ``--stale-json`` and ``--rows``
turn a classification into the remover's input and into printable rows.
Suppression-file handling and classification are in
``test_classify_suppressions.py``.
"""

from __future__ import annotations

import io
import json
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/security/classify-suppressions.py"
TOML = ".osv-scanner.toml"
CLEAN_SCAN = {
    "results": [],
    "experimental_config": {"licenses": {"summary": False, "allowlist": None}},
}


@pytest.fixture(name="classifier", scope="module")
def fixture_classifier(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the classifier once per module."""
    return load_script(SCRIPT)


@pytest.fixture(autouse=True)
def _no_inherited_config_path(monkeypatch: pytest.MonkeyPatch) -> None:
    """Drop a ``CONFIG_PATH`` from the developer's environment."""
    monkeypatch.delenv("CONFIG_PATH", raising=False)


def package(**fields: Any) -> dict[str, Any]:
    """Return one package entry of a probe, with ``fields`` added."""
    return {"package": {"name": "pkg", "version": "1.0.0", "ecosystem": "Go"}, **fields}


def scan(*packages: dict[str, Any]) -> str:
    """Return probe JSON with one result holding ``packages``."""
    source = {"path": "/repo/go.mod", "type": "lockfile"}
    return json.dumps({"results": [{"source": source, "packages": list(packages)}]})


def run_main(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    stdin: str,
    *argv: str,
) -> None:
    """Run ``main`` with ``argv`` and ``stdin``."""
    monkeypatch.setattr(sys, "argv", ["classify-suppressions.py", *argv])
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    classifier.main()


def fails_with(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
    *argv: str,
) -> str:
    """Run ``main``, assert exit 1 with one line and nothing printed; return it."""
    with pytest.raises(SystemExit) as exc_info:
        run_main(classifier, monkeypatch, stdin, *argv)

    captured = capsys.readouterr()
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(captured.out).is_empty()
    assert_that(captured.err.splitlines()).is_length(1)
    return captured.err


# --- parse_probe_vuln_ids


def test_ids_and_aliases_from_vulnerabilities_and_groups(
    classifier: ModuleType,
) -> None:
    """IDs, vulnerability aliases and group IDs and aliases all count."""
    output = scan(
        package(
            vulnerabilities=[
                {"id": "GHSA-present", "aliases": ["CVE-2024-00001"]},
                {"id": "GO-2024-1"},
            ],
            groups=[
                {
                    "ids": ["GHSA-present"],
                    "aliases": ["CVE-2024-00001", "GHSA-present", "PYSEC-1"],
                    "max_severity": "7.5",
                },
                {"ids": ["GO-2024-1"], "aliases": None, "max_severity": ""},
            ],
        ),
        package(license_violations=["MIT"]),
    )

    assert_that(classifier.parse_probe_vuln_ids(output)).is_equal_to(
        {"GHSA-present", "CVE-2024-00001", "GO-2024-1", "PYSEC-1"},
    )


def test_a_suppression_by_alias_is_active(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A present vulnerability suppressed by its CVE alias is not stale."""
    (workspace / TOML).write_text(
        '[[IgnoredVulns]]\nid = "CVE-2024-00001"\n',
        encoding="utf-8",
    )
    output = scan(
        package(
            vulnerabilities=[{"id": "GHSA-present", "aliases": ["CVE-2024-00001"]}],
            groups=[
                {
                    "ids": ["GHSA-present"],
                    "aliases": ["CVE-2024-00001", "GHSA-present"],
                    "max_severity": "",
                },
            ],
        ),
    )

    run_main(classifier, monkeypatch, output)

    assert_that(json.loads(capsys.readouterr().out)).is_equal_to(
        {
            "active": ["CVE-2024-00001"],
            "stale": [],
            "expired": [],
            "expired_until": {},
        },
    )


@pytest.mark.parametrize(
    "output",
    [json.dumps(CLEAN_SCAN), '{"results": []}'],
    ids=["osv-scanner-2.7.1", "minimal"],
)
def test_a_clean_scan_has_no_ids(classifier: ModuleType, output: str) -> None:
    """osv-scanner prints ``"results": []`` when nothing is found."""
    assert_that(classifier.parse_probe_vuln_ids(output)).is_empty()


def vuln_scan(vuln: Any) -> str:
    """Return a probe with one package holding ``vuln``."""
    return scan(package(vulnerabilities=[vuln]))


def group_scan(**group: Any) -> str:
    """Return a probe with one package holding a group with ``group``."""
    return scan(package(groups=[{"max_severity": "", **group}]))


@pytest.mark.parametrize(
    ("stdin", "detail"),
    [
        ("[]", "expected an object, got list"),
        ("null", "expected an object, got null"),
        ('"text"', "expected an object, got str"),
        ("{}", "output.results is missing"),
        ('{"error": "boom"}', "output.results is missing"),
        ('{"Results": []}', "output.results is missing"),
        ('{"results": null}', "output.results is null, not an array"),
        ('{"results": {}}', "output.results is dict, not an array"),
        ('{"results": [[]]}', "output.results holds list, not an object"),
        ('{"results": [{}]}', "results[].packages is missing"),
        ('{"results": [{"packages": null}]}', "results[].packages is null"),
        ('{"results": [{"packages": []}]}', "results[].packages is an empty array"),
        ('{"results": [{"packages": 1}]}', "results[].packages is int"),
        (
            scan(package(vulnerabilities=[])),
            "packages[].vulnerabilities is an empty array",
        ),
        (
            scan(package(vulnerabilities=None)),
            "packages[].vulnerabilities is null, not an array",
        ),
        (vuln_scan("GHSA-1"), "packages[].vulnerabilities holds str"),
        (vuln_scan({}), "vulnerabilities[].id is null, not a non-empty string"),
        (vuln_scan({"id": None}), "vulnerabilities[].id is null"),
        (vuln_scan({"id": ""}), "vulnerabilities[].id is an empty string"),
        (vuln_scan({"id": ["X"]}), "vulnerabilities[].id is list"),
        (vuln_scan({"id": {"X": 1}}), "vulnerabilities[].id is dict"),
        (vuln_scan({"id": 3}), "vulnerabilities[].id is int"),
        (
            vuln_scan({"id": "A", "aliases": None}),
            "vulnerabilities[].aliases is null",
        ),
        (
            vuln_scan({"id": "A", "aliases": []}),
            "vulnerabilities[].aliases is an empty array",
        ),
        (
            vuln_scan({"id": "A", "aliases": [7]}),
            "vulnerabilities[].aliases[] is int",
        ),
        (scan(package(groups=[])), "packages[].groups is an empty array"),
        (group_scan(aliases=["A"]), "groups[].ids is missing"),
        (group_scan(ids=["A"]), "groups[].aliases is missing"),
        (group_scan(ids="A", aliases=["A"]), "groups[].ids is str, not an array"),
        (group_scan(ids=["A"], aliases=[""]), "groups[].aliases[] is an empty string"),
        (group_scan(ids=[None], aliases=["A"]), "groups[].ids[] is null"),
        ("9" * 5000, "Exceeds the limit"),
        ("[" * 100_000, "nested too deeply to read"),
        ("{not json", "Expecting property name"),
    ],
)
def test_probe_json_in_the_wrong_shape_exits_1(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
    detail: str,
) -> None:
    """Anything but osv-scanner's shape fails, so it never reads as clean."""
    err = fails_with(classifier, monkeypatch, capsys, stdin)

    assert_that(err).starts_with(
        "ERROR: failed to parse osv-scanner JSON output: ",
    ).contains(detail)


# --- --stale-json and --rows


CLASSIFICATION = {
    "active": ["GHSA-active", "a|b"],
    "stale": ["GHSA-stale", "CVE-2024-1"],
    "expired": ["GHSA-old", "x`y"],
    "expired_until": {"GHSA-old": "2020-01-01", "x`y": "2021-02-03"},
}


def test_stale_json_is_the_stale_array_exactly(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The remove list is the classifier's own array, not re-encoded rows."""
    stale = [" GHSA-x ", "a\tb\nc", "é"]
    classification = {**CLASSIFICATION, "stale": stale}

    run_main(classifier, monkeypatch, json.dumps(classification), "--stale-json")

    out = capsys.readouterr().out
    assert_that(json.loads(out)).is_equal_to(stale)
    assert_that(out.splitlines()).is_length(1)


def test_rows_hold_printable_ids_only(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Each row is ``CATEGORY<TAB>id<TAB>date`` with the ID made printable."""
    classification = {
        **CLASSIFICATION,
        "stale": ["GHSA-stale", "x\nSTALE\tGHSA-active"],
        "expired": ["GHSA-old", "x`y", "NO-DATE"],
    }

    run_main(classifier, monkeypatch, json.dumps(classification), "--rows")

    assert_that(capsys.readouterr().out.splitlines()).is_equal_to(
        [
            "STALE\tGHSA-stale\t",
            'STALE\t"x\\nSTALE\\tGHSA-active"\t',
            "ACTIVE\tGHSA-active\t",
            'ACTIVE\t"a\\u007cb"\t',
            "EXPIRED\tGHSA-old\t2020-01-01",
            'EXPIRED\t"x\\u0060y"\t2021-02-03',
            "EXPIRED\tNO-DATE\t",
        ],
    )


@pytest.mark.parametrize(
    ("stdin", "detail"),
    [
        ("", "classification JSON is not readable: JSONDecodeError"),
        ("[" * 100_000, "classification JSON is not readable: RecursionError"),
        ("[]", "classification JSON: expected an object, got list"),
        ('{"expired_until": []}', "expired_until must map IDs to strings"),
        ('{"expired_until": {"A": 1}}', "expired_until must map IDs to strings"),
        ('{"expired_until": {}}', "classification JSON: active must be an array"),
        (
            '{"expired_until": {}, "active": [], "stale": [1]}',
            "classification JSON: stale must be an array of strings",
        ),
    ],
)
@pytest.mark.parametrize("mode", ["--rows", "--stale-json"])
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_an_unusable_classification_exits_1(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
    detail: str,
    mode: str,
) -> None:
    """Both modes refuse anything but a classification this script printed."""
    err = fails_with(classifier, monkeypatch, capsys, stdin, mode)

    assert_that(err).starts_with("ERROR: ").contains(detail)


@pytest.mark.parametrize("argv", [["--row"], ["--rows", "--stale-json"], ["x"]])
def test_unknown_arguments_exit_1(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    argv: list[str],
) -> None:
    """Anything but no argument, ``--rows`` or ``--stale-json`` is refused."""
    err = fails_with(classifier, monkeypatch, capsys, "{}", *argv)

    assert_that(err).starts_with("ERROR: unknown arguments")


@pytest.mark.parametrize(
    ("vuln_id", "expected"),
    [
        ("GHSA-abcd-1234", "GHSA-abcd-1234"),
        (" A", '" A"'),
        ("a\tb\nc", '"a\\tb\\nc"'),
        ("`|%é", '"\\u0060\\u007c\\u0025\\u00e9"'),
    ],
)
def test_shown_makes_any_id_one_safe_line(
    classifier: ModuleType,
    vuln_id: str,
    expected: str,
) -> None:
    """Plain IDs print as is; anything else is quoted and escaped."""
    assert_that(classifier.shown(vuln_id)).is_equal_to(expected)
