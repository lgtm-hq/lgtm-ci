# SPDX-License-Identifier: MIT
"""Probe parsing and shell output of ``scripts/ci/security/classify-suppressions.py``.

The probe must be what ``osv-scanner scan --recursive --format json
--config <file>`` 2.7.1 can print (``pkg/models/results.go``,
``pkg/osvscanner/filter.go``, ``determineReturnErr`` in
``pkg/osvscanner/osvscanner.go``, and the JSON snapshots of that tag);
anything else is an error, never a clean scan. The probe run must also be
complete: its exit status must be the one its output implies, and its stderr
must name no error. ``--stale-json`` and ``--rows`` turn a classification
into the remover's input and into printable rows. Suppression-file handling
and classification are in ``test_classify_suppressions.py``.
"""

from __future__ import annotations

import io
import json
import os
import sys
import time
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
def _clean_environment(monkeypatch: pytest.MonkeyPatch) -> Any:
    """Drop inherited variables; pin the one clock and the zone (UTC)."""
    for name in ("CONFIG_PATH", "PROBE_EXIT", "PROBE_STDERR_FILE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("CHECK_NOW", "2026-06-15T12:00:00Z")
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


def group(*ids: str, **fields: Any) -> dict[str, Any]:
    """Return one group of a probe holding ``ids``, with ``fields`` added."""
    return {"ids": list(ids), "aliases": list(ids), "max_severity": "", **fields}


def package(*ids: str, **fields: Any) -> dict[str, Any]:
    """Return one package of a probe with ``ids`` in one group each."""
    return {
        "package": {"name": "pkg", "version": "1.0.0", "ecosystem": "Go"},
        "vulnerabilities": [{"id": vuln_id} for vuln_id in ids],
        "groups": [group(vuln_id) for vuln_id in ids],
        **fields,
    }


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


# --- parse_probe


def test_ids_and_aliases_from_vulnerabilities_and_groups(
    classifier: ModuleType,
) -> None:
    """IDs, vulnerability aliases and group IDs and aliases all count."""
    output = scan(
        {
            "package": {"name": "x", "version": "1", "ecosystem": "PyPI"},
            "vulnerabilities": [
                {"id": "GHSA-present", "aliases": ["CVE-2024-00001"]},
                {"id": "GO-2024-1"},
            ],
            "groups": [
                {
                    "ids": ["GHSA-present"],
                    "aliases": ["CVE-2024-00001", "GHSA-present", "PYSEC-1"],
                    "max_severity": "7.5",
                },
                group("GO-2024-1"),
            ],
        },
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
    probe_run(monkeypatch, workspace, "1", "")
    (workspace / TOML).write_text(
        '[[IgnoredVulns]]\nid = "CVE-2024-00001"\n',
        encoding="utf-8",
    )
    output = scan(
        {
            "package": {"name": "x", "version": "1", "ecosystem": "npm"},
            "vulnerabilities": [{"id": "GHSA-present", "aliases": ["CVE-2024-00001"]}],
            "groups": [
                {
                    "ids": ["GHSA-present"],
                    "aliases": ["CVE-2024-00001", "GHSA-present"],
                    "max_severity": "",
                },
            ],
        },
    )

    run_main(classifier, monkeypatch, output)

    result = json.loads(capsys.readouterr().out)
    assert_that(result["active"]).is_equal_to(["CVE-2024-00001"])
    assert_that(result["stale"]).is_empty()


@pytest.mark.parametrize(
    "output",
    [json.dumps(CLEAN_SCAN), '{"results": []}'],
    ids=["osv-scanner-2.7.1", "minimal"],
)
def test_a_clean_scan_has_no_ids(classifier: ModuleType, output: str) -> None:
    """osv-scanner prints ``"results": []`` when nothing is found."""
    assert_that(tuple(classifier.parse_probe(output))).is_equal_to((set(), 0))


CALLED_UNIMPORTANT = {"called": True, "unimportant": True}
FORGED_ROW = '"\\u0023\\u0023[error] forged \\u003a\\u003a description"'
CALLED_AS_INT = {"A": {"called": 1}}


def without_groups(pkg: dict[str, Any]) -> dict[str, Any]:
    """Return ``pkg`` without its ``groups`` key."""
    return {key: value for key, value in pkg.items() if key != "groups"}


def analysis(**flags: dict[str, bool]) -> dict[str, Any]:
    """Return ``experimental_analysis`` mapping each ID to its flags."""
    return {"experimental_analysis": flags}


@pytest.mark.parametrize(
    ("packages", "expected"),
    [
        ([package("A")], 1),
        ([package("A", groups=[group("A", **analysis(A={"called": False}))])], 0),
        (
            [package("A", groups=[group("A", **analysis(A={"called": True}))])],
            1,
        ),
        (
            [
                package(
                    "A",
                    groups=[group("A", **analysis(A=CALLED_UNIMPORTANT))],
                ),
            ],
            0,
        ),
        (
            [
                package("A", groups=[group("A", **analysis(A={"called": False}))]),
                package("B"),
            ],
            1,
        ),
    ],
    ids=["no-analysis", "uncalled", "called", "unimportant", "one-important"],
)
def test_expected_exit_follows_determine_return_err(
    classifier: ModuleType,
    packages: list[dict[str, Any]],
    expected: int,
) -> None:
    """Exit 1 needs a called, not unimportant vulnerability; else 0."""
    assert_that(classifier.parse_probe(scan(*packages)).expected_exit).is_equal_to(
        expected,
    )


def vuln_scan(vuln: Any) -> str:
    """Return a probe with one package holding ``vuln`` and a group for "A"."""
    return scan(package("A", vulnerabilities=[vuln]))


def group_scan(**fields: Any) -> str:
    """Return a probe with one vulnerability "A" and a group made of ``fields``."""
    return scan(package("A", groups=[{"max_severity": "", **fields}]))


WRONG_SHAPES = [
    ("[]", "expected an object, got list"),
    ("null", "expected an object, got null"),
    ("{}", "output.results is missing"),
    ('{"error": "boom"}', "output.results is missing"),
    ('{"Results": []}', "output.results is missing"),
    ('{"results": null}', "output.results is null, not an array"),
    ('{"results": {}}', "output.results is dict, not an array"),
    ('{"results": [[]]}', "output.results holds list, not an object"),
    ('{"results": [{}]}', "results[].packages is missing"),
    ('{"results": [{"packages": []}]}', "results[].packages is an empty array"),
    ('{"results": [{"packages": [1]}]}', "results[].packages holds int"),
    ('{"results": [{"packages": [{"package": {}}]}]}', "vulnerabilities is missing"),
    (scan({"package": {}, "vulns": [{"id": "A"}]}), "vulnerabilities is missing"),
    (scan({"vulnerabilities": []}), "packages[].package is missing"),
    (scan(package("A", vulnerabilities=[])), "vulnerabilities is an empty array"),
    (scan(package("A", vulnerabilities=None)), "vulnerabilities is null"),
    (scan(package("A", groups=None)), "packages[].groups is null"),
    (scan(without_groups(package("A"))), "groups is missing"),
    (scan(package("A", license_violations=["MIT"])), "license_violations is present"),
    (scan(package("A", licenses=["MIT"])), "packages[].licenses is present"),
    (
        scan(package("A", package={"name": "x", "deprecated": True})),
        "package.deprecated is present",
    ),
    (vuln_scan("GHSA-1"), "packages[].vulnerabilities holds str"),
    (vuln_scan({}), "vulnerabilities[].id is null, not a non-empty string"),
    (vuln_scan({"id": ""}), "vulnerabilities[].id is an empty string"),
    (vuln_scan({"id": ["A"]}), "vulnerabilities[].id is list"),
    (vuln_scan({"id": 3}), "vulnerabilities[].id is int"),
    (vuln_scan({"id": "A", "aliases": None}), "vulnerabilities[].aliases is null"),
    (vuln_scan({"id": "A", "aliases": []}), "aliases is an empty array"),
    (vuln_scan({"id": "A", "aliases": [7]}), "vulnerabilities[].aliases[] is int"),
    (group_scan(aliases=["A"]), "groups[].ids is missing"),
    (group_scan(ids=["A"]), "groups[].aliases is missing"),
    (group_scan(ids=None, aliases=["A"]), "groups[].ids is null, not an array"),
    (group_scan(ids=["A"], aliases=None), "groups[].aliases is null, not an array"),
    (group_scan(ids=["A"], aliases=[""]), "groups[].aliases[] is an empty string"),
    (group_scan(ids=["B"], aliases=["B"]), "groups do not list the package's"),
    (
        group_scan(ids=["A"], aliases=["A"], experimental_analysis=[]),
        "experimental_analysis is not an object of objects",
    ),
    (
        group_scan(ids=["A"], aliases=["A"], experimental_analysis={"A": 1}),
        "experimental_analysis is not an object of objects",
    ),
    (
        group_scan(ids=["A"], aliases=["A"], experimental_analysis=CALLED_AS_INT),
        "flag that is not a boolean",
    ),
    ('{"results": [], "results": [1]}', "duplicate key 'results'"),
    ('{"results": [{"packages": NaN}]}', "NaN is not a JSON value"),
    ('{"results": [], "x": -Infinity}', "-Infinity is not a JSON value"),
    ("9" * 5000, "Exceeds the limit"),
    ("[" * 100_000, "nested too deeply to read"),
    ("{not json", "Expecting property name"),
]


@pytest.mark.parametrize(("stdin", "detail"), WRONG_SHAPES)
def test_probe_json_in_the_wrong_shape_exits_1(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
    detail: str,
) -> None:
    """Anything this probe cannot print fails, so it never reads as clean."""
    err = fails_with(classifier, monkeypatch, capsys, stdin)

    assert_that(err).starts_with(
        "ERROR: failed to parse osv-scanner JSON output: ",
    ).contains(detail)


# --- the probe run


HEALTHY_FORMS = [
    "Scanning dir .",
    "Scanned /repo/pkg/errors/go.mod file and found 3 packages",
    "Scanned /repo/failing tests/package-lock.json file and found 1 package",
    "Scanned /repo/empty/requirements.txt file and found 0 packages",
    "Filtered 1 local/unscannable package/s from the scan.",
    "Filtered 12 local/unscannable package/s from the scan.",
    "Starting filesystem walk for root: /home/runner/work/repo/repo",
    "End status: 12 dirs visited, 340 inodes visited, 4 Extract calls, "
    "1.2345ms elapsed, 1m2.5s wall time",
    'Status: new inodes: 1200, 950.3 inodes/s, new extract calls: 3, path: "a/b"',
    "Warning: enricher transitivedependency/pomxml may be risky when run on "
    "untrusted artifacts. Please ensure you trust the source code and artifacts.",
    "The default Maven registry is being overwritten from "
    "https://repo.maven.apache.org/maven2 to https://maven.example.org/repo",
]
HEALTHY_STDERR = "\n".join(HEALTHY_FORMS) + "\n\n"


def probe_run(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    exit_status: str,
    stderr: str,
) -> None:
    """Set ``PROBE_EXIT`` and ``PROBE_STDERR_FILE`` for one probe run."""
    stderr_file = tmp_path / "probe-stderr"
    stderr_file.write_text(stderr, encoding="utf-8")
    monkeypatch.setenv("PROBE_EXIT", exit_status)
    monkeypatch.setenv("PROBE_STDERR_FILE", str(stderr_file))


@pytest.mark.usefixtures("workspace")
@pytest.mark.parametrize(
    ("stdin", "exit_status"),
    [(scan(package("A")), "1"), ('{"results": []}', "0")],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_a_consistent_healthy_run_is_classified(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    stdin: str,
    exit_status: str,
) -> None:
    """Every form a complete scan prints, in one run, is accepted."""
    probe_run(monkeypatch, tmp_path, exit_status, HEALTHY_STDERR)

    run_main(classifier, monkeypatch, stdin)

    assert_that(json.loads(capsys.readouterr().out)).contains_key("stale")


@pytest.mark.parametrize("line", HEALTHY_FORMS)
def test_each_healthy_form_is_recognised(classifier: ModuleType, line: str) -> None:
    """Each allowed form passes on its own, with trailing whitespace."""
    assert_that(classifier.stderr_problem(f"\n{line} \r\n\n")).is_none()


UNKNOWN_LINES = [
    'openAndExtractFromFile("/repo/dependencies.lock"): bufio.Scanner: token too long',
    "Error during extraction: (extracting as php/composerlock) "
    "/repo/composer.lock: could not extract: invalid character ','",
    "failed resolution for /repo/requirements.txt: dial tcp: no such host",
    "Loaded filter from: /tmp/probe.toml",
    "Loaded npm local db from /tmp/osv-scalibr/npm/all.zip",
    "Failed to read config file: open x: permission denied",
    "panic: runtime error: index out of range",
    "Scanning dir /somewhere/else",
    "Scanned /repo/a.lock file and found 1 packages",
    "Scanned /repo/a.lock file and found 2 package",
    "Scanned /repo/a.lock file and found 1 package, then failed",
    " Scanning dir .",
    "Filtered 0 local/unscannable package/s from the scan.",
    "End status: 1 dirs visited, 2 inodes visited, 3 Extract calls, soon elapsed, 1s",
    'Disabling plugin "python/requirements": requirement not met',
    "unsupported file extension for requirements: .zip",
    "anything else at all",
    # A package with a known identity that was never looked up.
    'Skipping django: short commit hash "ad9fa56" cannot be queried; OSV API '
    "requires a full 40-character SHA.",
    # Call analysis is off for the probe; its lines are no longer accepted.
    "Skipping call analysis on Go code since Go is not installed.",
    "Failed to run code analysis (govulncheck) on '/repo/go.mod' because x",
    "(the Go toolchain is required)",
]


def test_filtered_alone_passes_but_not_with_a_skipped_package(
    classifier: ModuleType,
) -> None:
    """The bare filtered line is healthy; the short-hash line still fails."""
    filtered = "Filtered 1 local/unscannable package/s from the scan.\n"
    skipping = (
        'Skipping django: short commit hash "ad9fa56" cannot be queried; OSV API '
        "requires a full 40-character SHA."
    )

    assert_that(classifier.stderr_problem(filtered)).is_none()
    assert_that(classifier.stderr_problem(skipping + "\n" + filtered)).is_equal_to(
        skipping,
    )


def test_a_forged_opener_cannot_swallow_an_error(classifier: ModuleType) -> None:
    """Every physical line is judged alone, so nothing spans an error."""
    forged = (
        "Scanned /repo/a file and found 1 package\n"
        "Failed to run code analysis (govulncheck) on 'forged' because injected\n"
        'openAndExtractFromFile("/repo/dependencies.lock"): bufio.Scanner: '
        "token too long\n"
        "(the Go toolchain is required)\n"
    )

    assert_that(classifier.stderr_problem(forged)).starts_with("Failed to run")


@pytest.mark.usefixtures("workspace")
@pytest.mark.parametrize("line", UNKNOWN_LINES)
def test_any_other_line_fails_the_run(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    line: str,
) -> None:
    """Only known forms are trusted; the unknown line is quoted for a report."""
    probe_run(monkeypatch, tmp_path, "1", HEALTHY_STDERR + line + "\n")

    err = fails_with(classifier, monkeypatch, capsys, scan(package("A")))

    assert_that(err).starts_with(
        "ERROR: osv-scanner printed a line that a complete scan does not print, "
        "so the scan may be incomplete and nothing is classified or removed: ",
    ).ends_with(
        ". If the line is harmless, report it so the list of known osv-scanner "
        "messages can be extended.\n",
    )


@pytest.mark.usefixtures("workspace")
@pytest.mark.parametrize(
    ("stdin", "exit_status", "detail"),
    [
        ('{"results": []}', "1", "osv-scanner exited 1 but its output implies 0"),
        (scan(package("A")), "0", "osv-scanner exited 0 but its output implies 1"),
        ('{"results": []}', "2", "PROBE_EXIT must be 0 or 1, not 2"),
        ('{"results": []}', " 0", 'PROBE_EXIT must be 0 or 1, not " 0"'),
    ],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_an_inconsistent_exit_status_fails(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    stdin: str,
    exit_status: str,
    detail: str,
) -> None:
    """Exit 1 without a finding, or 0 with one, means the scan is not whole."""
    probe_run(monkeypatch, tmp_path, exit_status, "")

    err = fails_with(classifier, monkeypatch, capsys, stdin)

    assert_that(err).starts_with("ERROR: ").contains(detail)


@pytest.mark.usefixtures("workspace")
@pytest.mark.parametrize("present", [["PROBE_EXIT"], ["PROBE_STDERR_FILE"], []])
def test_the_scan_checks_cannot_be_skipped(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    present: list[str],
) -> None:
    """Without both probe inputs the default mode classifies nothing."""
    probe_run(monkeypatch, tmp_path, "0", "")
    for name in ("PROBE_EXIT", "PROBE_STDERR_FILE"):
        if name not in present:
            monkeypatch.delenv(name)

    err = fails_with(classifier, monkeypatch, capsys, '{"results": []}')

    assert_that(err).is_equal_to(
        "ERROR: PROBE_EXIT and PROBE_STDERR_FILE must both be set: without them "
        "the scan cannot be checked, so nothing is classified\n",
    )


@pytest.mark.usefixtures("workspace")
def test_an_unknown_line_is_printed_safely(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """The quoted scanner line cannot act as a runner command."""
    probe_run(monkeypatch, tmp_path, "0", "error ##[error]forged `x` | y" + "z" * 300)

    err = fails_with(classifier, monkeypatch, capsys, '{"results": []}')

    assert_that(err).does_not_contain("##[").does_not_contain("`").contains(
        "more characters)",
    )


@pytest.mark.usefixtures("workspace")
def test_an_unreadable_stderr_file_fails(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A probe run whose stderr cannot be checked is not trusted."""
    monkeypatch.setenv("PROBE_EXIT", "0")
    monkeypatch.setenv("PROBE_STDERR_FILE", str(tmp_path / "missing"))

    err = fails_with(classifier, monkeypatch, capsys, '{"results": []}')

    assert_that(err).starts_with("ERROR: cannot read PROBE_STDERR_FILE ")


# --- --check-paths


def make_tree(root: Path, *names: str) -> Path:
    """Create files and directories (names ending in "/") under ``root``."""
    for name in names:
        target = root / name
        if name.endswith("/"):
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("", encoding="utf-8")
    return root


def test_a_tree_without_control_characters_passes(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """Spaces, quotes and non-ASCII letters are fine; only controls fail."""
    root = make_tree(
        tmp_path,
        "a b/requirements.txt",
        "é/x file and found 1 package",
        "q'\"/",
        ".git/HEAD",
    )
    (root / "link").symlink_to(root / "a b")

    assert_that(classifier.control_path(str(root))).is_none()


@pytest.mark.parametrize(
    "name",
    ["dir\nname/", "file\rname", "tab\tname", "esc\x1bname", "c1\x85name/", "del\x7f"],
)
def test_a_control_character_anywhere_is_found(
    classifier: ModuleType,
    tmp_path: Path,
    name: str,
) -> None:
    """A newline, carriage return, tab or any C0/C1 control fails."""
    try:
        make_tree(tmp_path, f"deep/{name}")
    except OSError:
        pytest.skip("this filesystem cannot hold that name")

    found = classifier.control_path(str(tmp_path))

    assert_that(found).is_equal_to(str(tmp_path / "deep" / name.rstrip("/")))


def test_a_control_character_above_the_root_is_found(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """A relative root is also checked as an absolute path."""
    parent = make_tree(tmp_path / "parent\nname", "repo/a.txt")
    monkeypatch.chdir(parent / "repo")

    assert_that(classifier.control_path(".")).is_equal_to(str(parent / "repo"))


def test_a_control_character_behind_a_symlinked_root_is_found(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """The root is also checked with symbolic links resolved."""
    real = make_tree(tmp_path / "real\nname", "a.txt")
    link = tmp_path / "link"
    link.symlink_to(real)

    assert_that(classifier.control_path(str(link))).is_equal_to(str(real))


def test_a_name_that_is_not_utf8_is_found(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """Bytes that are not UTF-8 come back as surrogates and are refused."""
    try:
        (tmp_path / os.fsdecode(b"bad\xffname")).write_text("", encoding="utf-8")
    except OSError:
        pytest.skip("this filesystem cannot hold a name that is not UTF-8")

    found = classifier.control_path(str(tmp_path))

    assert_that(found).is_equal_to(str(tmp_path / os.fsdecode(b"bad\xffname")))


def test_a_control_character_in_the_root_is_found(
    classifier: ModuleType,
    tmp_path: Path,
) -> None:
    """The root itself is checked too."""
    root = make_tree(tmp_path / "root\nname", "a.txt")

    assert_that(classifier.control_path(str(root))).is_equal_to(str(root))


def test_an_unlistable_directory_fails(
    classifier: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A directory that cannot be listed cannot be checked: exit 1."""
    with pytest.raises(SystemExit) as exc_info:
        classifier.control_path(str(tmp_path / "missing"))

    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(capsys.readouterr().err).starts_with("ERROR: cannot list ")


def test_check_paths_mode_passes_a_clean_tree(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """The mode prints nothing when no path holds a control character."""
    make_tree(tmp_path, "ok.txt")

    run_main(classifier, monkeypatch, "", "--check-paths", str(tmp_path))

    assert_that(capsys.readouterr().err).is_empty()


def test_check_paths_mode_fails_with_one_safe_line(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A newline in a name fails with one ERROR line that is safe to print."""
    make_tree(tmp_path, "bad\n##[x]")
    root = str(tmp_path)

    err = fails_with(classifier, monkeypatch, capsys, "", "--check-paths", root)

    assert_that(err).starts_with(
        "ERROR: a path under the scan root holds a control character, so "
        "osv-scanner's messages about it cannot be read safely and nothing is "
        "classified or removed: ",
    ).does_not_contain("##[")


# --- --stale-json and --rows


CLASSIFICATION = {
    "active": ["GHSA-active", "a|b"],
    "stale": ["GHSA-stale", "CVE-2024-1"],
    "expired": ["GHSA-old", "x`y"],
    "expired_until": {"GHSA-old": "2020-01-01", "x`y": "2021-02-03T10:00:00+00:00"},
    "not_understood": ["entry 3, id 'A': unknown key 'note'"],
    "scan_checked": True,
    "held_back": ["A"],
}
FIRST_PASS = {**CLASSIFICATION, "active": [], "stale": [], "scan_checked": False}


def first_pass(tmp_path: Path, **fields: Any) -> str:
    """Write a first-pass (``--expired``) result and return its path."""
    path = tmp_path / "first-pass.json"
    path.write_text(json.dumps({**FIRST_PASS, **fields}), encoding="utf-8")
    return str(path)


def test_stale_json_is_the_stale_array_exactly(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """The remove list is the classifier's own array, not re-encoded rows."""
    stale = [" GHSA-x ", "a\tb\nc", "é"]

    run_main(
        classifier,
        monkeypatch,
        json.dumps({**CLASSIFICATION, "stale": stale}),
        "--stale-json",
        first_pass(tmp_path),
    )

    out = capsys.readouterr().out
    assert_that(json.loads(out)).is_equal_to(stale)
    assert_that(out.splitlines()).is_length(1)


def test_rows_hold_printable_text_only(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Each row is ``CATEGORY<TAB>text<TAB>date`` with every value printable."""
    classification = {
        **CLASSIFICATION,
        "stale": ["GHSA-stale", "x\nSTALE\tGHSA-active", "X##[error]forged-id"],
        "expired": ["GHSA-old", "x`y", "NO-DATE"],
        "not_understood": [
            "entry 3, id 'A': unknown key 'note'",
            "##[error] forged :: description",
            "L" * 250,
        ],
    }

    run_main(classifier, monkeypatch, json.dumps(classification), "--rows")

    assert_that(capsys.readouterr().out.splitlines()).is_equal_to(
        [
            "STALE\tGHSA-stale\t",
            'STALE\t"x\\nSTALE\\tGHSA-active"\t',
            'STALE\t"X\\u0023\\u0023[error]forged-id"\t',
            "ACTIVE\tGHSA-active\t",
            'ACTIVE\t"a\\u007cb"\t',
            "EXPIRED\tGHSA-old\t2020-01-01",
            'EXPIRED\t"x\\u0060y"\t2021-02-03T10:00:00+00:00',
            "EXPIRED\tNO-DATE\t",
            "NOT_UNDERSTOOD\tentry 3, id 'A': unknown key 'note'\t",
            f"NOT_UNDERSTOOD\t{FORGED_ROW}\t",
            f"NOT_UNDERSTOOD\t{'L' * 200}... (50 more characters)\t",
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
        (
            '{"expired_until": {}, "scan_checked": true}',
            "classification JSON: active must be an array",
        ),
        (
            '{"expired_until": {}, "active": [], "stale": [1], "scan_checked": true}',
            "classification JSON: stale must be an array of strings",
        ),
        (
            '{"expired_until": {}, "active": [], "stale": [], "expired": [], '
            '"scan_checked": true}',
            "classification JSON: not_understood must be an array of strings",
        ),
        (
            '{"expired_until": {}, "active": [], "stale": [], "expired": [], '
            '"scan_checked": true, "not_understood": []}',
            "classification JSON: held_back must be an array of strings",
        ),
        (
            '{"expired_until": {}, "scan_checked": "yes"}',
            "classification JSON: scan_checked must be true or false",
        ),
        (
            '{"expired_until": {}}',
            "classification JSON: scan_checked must be true or false",
        ),
    ],
)
@pytest.mark.parametrize("mode", [["--rows"], ["--stale-json", "unused"]])
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_an_unusable_classification_exits_1(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stdin: str,
    detail: str,
    mode: list[str],
) -> None:
    """Both modes refuse anything but a classification this script printed."""
    err = fails_with(classifier, monkeypatch, capsys, stdin, *mode)

    assert_that(err).starts_with("ERROR: ").contains(detail)


def test_stale_json_refuses_an_unchecked_classification(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Only a classification from a checked scan can name IDs to remove."""
    unchecked = json.dumps({**CLASSIFICATION, "scan_checked": False})
    first = first_pass(tmp_path)

    err = fails_with(classifier, monkeypatch, capsys, unchecked, "--stale-json", first)

    assert_that(err).is_equal_to(
        "ERROR: classification JSON: the scan was not checked (scan_checked is "
        "not true), so no ID may be removed\n",
    )


def test_expired_mode_needs_no_probe(
    classifier: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Expiry and not-understood entries come from the file and the clock."""
    (workspace / TOML).write_text(
        '[[IgnoredVulns]]\nid = "OLD"\neffectiveUntil = 2020-01-01\n\n'
        '[[IgnoredVulns]]\nid = "LIVE"\n\n'
        '[[IgnoredVulns]]\nid = "ODD"\nnote = "x"\n',
        encoding="utf-8",
    )

    run_main(classifier, monkeypatch, "", "--expired")

    assert_that(json.loads(capsys.readouterr().out)).is_equal_to(
        {
            "active": [],
            "stale": [],
            "expired": ["OLD"],
            "expired_until": {"OLD": "2020-01-01"},
            "not_understood": ["entry 3, id 'ODD': unknown key 'note'"],
            "scan_checked": False,
            "held_back": ["ODD"],
        },
    )


@pytest.mark.parametrize(
    ("first", "second", "clash"),
    [
        ({"expired": ["X"]}, {}, "X"),
        ({"held_back": ["X"]}, {}, "X"),
        ({}, {"expired": ["X"]}, "X"),
        ({}, {"held_back": ["X"]}, "X"),
    ],
    ids=["expired-first", "held-first", "expired-second", "held-second"],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_an_id_kept_by_either_pass_and_stale_in_the_second_fails(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    first: dict[str, Any],
    second: dict[str, Any],
    clash: str,
) -> None:
    """Expired or held back in one pass, stale in the other: remove nothing."""
    path = first_pass(tmp_path, **{"expired": [], "held_back": [], **first})
    stdin = json.dumps({**CLASSIFICATION, "stale": ["OK", clash], **second})

    err = fails_with(classifier, monkeypatch, capsys, stdin, "--stale-json", path)

    assert_that(err).is_equal_to(
        "ERROR: the two passes disagree: expired or held back in one, stale in "
        f"the other ({clash}), so nothing is removed\n",
    )


@pytest.mark.parametrize("content", [None, "[not json"])
def test_an_unusable_first_pass_fails(
    classifier: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    content: str | None,
) -> None:
    """Without a readable first pass nothing is removed."""
    path = tmp_path / "first-pass.json"
    if content is not None:
        path.write_text(content, encoding="utf-8")
    stdin = json.dumps(CLASSIFICATION)

    err = fails_with(classifier, monkeypatch, capsys, stdin, "--stale-json", str(path))

    assert_that(err).starts_with("ERROR: ")


@pytest.mark.parametrize(
    ("path", "problem"),
    [
        ("ok/name", None),
        ("bad\nname", "holds a control character"),
        ("bad\udcffname", "is not valid UTF-8"),
    ],
)
def test_path_problem_names_the_reason(
    classifier: ModuleType,
    path: str,
    problem: str | None,
) -> None:
    """A name that is not UTF-8 is reported as such, not as a control."""
    assert_that(classifier.path_problem(path)).is_equal_to(problem)


@pytest.mark.parametrize(
    "argv",
    [
        ["--row"],
        ["--rows", "--stale-json"],
        ["x"],
        ["--check-paths"],
        ["--check-paths", "a", "b"],
    ],
)
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
        ("PYSEC-2024.1:x_y+z", "PYSEC-2024.1:x_y+z"),
        ("A::B", '"A\\u003a\\u003aB"'),
        (" A", '" A"'),
        ("a\tb\nc", '"a\\tb\\nc"'),
        ("`|%#é", '"\\u0060\\u007c\\u0025\\u0023\\u00e9"'),
    ],
)
def test_shown_makes_any_id_one_safe_line(
    classifier: ModuleType,
    vuln_id: str,
    expected: str,
) -> None:
    """Plain IDs print as is; anything else is quoted and escaped."""
    assert_that(classifier.shown(vuln_id)).is_equal_to(expected)
