# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/actions/shard-completion.py`` (#1531).

A shard writes ``shard-complete.json`` only when kcov finished and its TAP
plan completed; the aggregate merges coverage and publishes totals only when
every expected shard has one.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/actions/shard-completion.py"
COBERTURA = (
    '<?xml version="1.0" ?>\n'
    '<coverage line-rate="0.5" lines-covered="3" lines-valid="6" version="1">\n'
    "</coverage>\n"
)
SHA = "0123abcd"
HOOK = "(a setup_file/hook failure or an interruption)"
# Trimmed shard-0 TAP of CI run 43401834823: noise before the plan, the
# 1..794 plan, every top-level result and a verbatim block of leaked
# nested TAP (ok 1 / 1..1 lines from tests that run bats themselves).
FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
SHARD_FIXTURE = FIXTURES / "tap" / "shard-leaked-nested.tap.txt"
REASON = (
    "incomplete coverage: shard(s) 3, 4 did not finish (no completion manifest: "
    "a setup_file/hook failure, an interruption or a lost upload)"
)
# Verbatim Bats 1.14 output: a.bats has a failing setup_file and two tests,
# b.bats one passing test. Uninterrupted, yet incomplete: TAP cannot tell it
# from the SIGTERM case below.
BATS_SETUP_FILE_FAILED = (
    "1..3\n"
    "not ok 1 setup_file failed\n"
    "# (from function `setup_file' in test file a.bats, line 2)\n"
    "#   `setup_file() { false; }' failed\n"
    "ok 3 c\n"
    "# bats warning: Executed 2 instead of expected 3 tests\n"
)
# Bats 1.14 output, a.bats as above plus b.bats with two tests, when SIGINT
# reaches the process group during b.bats's first test: 2 results of 1..4.
BATS_SIGINT = (
    "1..4\n"
    "not ok 1 setup_file failed\n"
    "# (from function `setup_file' in test file a.bats, line 2)\n"
    "#   `setup_file() { false; }' failed\n"
    "not ok 3 c\n"
    "# (in test file b.bats, line 1)\n"
    "#   `#!/usr/bin/env bats' failed with status 130\n"
    "\n"
    "# Received SIGINT, aborting ...\n"
    "\n"
    "# bats warning: Executed 2 instead of expected 4 tests\n"
)
# Sol's case (Bats 1.14, also with --jobs 2): SIGTERM kills b.bats's
# bats-exec-file during its first test. Bats exits 1 with no SIG marker and
# the same closing warning as an uninterrupted setup_file failure.
BATS_SIGTERM = (
    "1..4\n"
    "not ok 1 setup_file failed\n"
    "# (from function `setup_file' in test file a.bats, line 2)\n"
    "#   `setup_file() { false; }' failed\n"
    "ok 3 c\n"
    "# bats warning: Executed 2 instead of expected 4 tests\n"
)
BATS_TEARDOWN_FILE_FAILED = (
    "1..1\n"
    "ok 1 a\n"
    "not ok 2 teardown_file failed\n"
    "# bats warning: Executed 2 instead of expected 1 tests\n"
)


@pytest.fixture(name="mod")
def fixture_mod(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the hyphenated script as a module."""
    return load_script(SCRIPT_PATH)


def _tap(planned: int, results: int) -> str:
    """Return a TAP stream with a ``1..planned`` plan and ``results`` lines."""
    lines = [f"1..{planned}"]
    lines += [f"ok {number} test {number}" for number in range(1, results + 1)]
    return "\n".join(lines) + "\n"


def _shard(
    root: Path,
    *,
    tap: str,
    report: str | None = COBERTURA,
) -> tuple[Path, Path]:
    """Lay out one shard's coverage dir and TAP file; return both paths."""
    coverage_dir = root / "coverage-report"
    (coverage_dir / "kcov-merged").mkdir(parents=True)
    if report is not None:
        (coverage_dir / "kcov-merged" / "cov.xml").write_text(report, encoding="utf-8")
    tap_path = root / "bats-output.tap"
    tap_path.write_text(tap, encoding="utf-8")
    return coverage_dir, tap_path


def _write(
    mod: ModuleType,
    coverage_dir: Path,
    tap_path: Path,
    exit_code: int,
) -> Path:
    """Call ``write_manifest`` for shard 3 of 8."""
    return Path(
        mod.write_manifest(
            coverage_dir=coverage_dir,
            tap_path=tap_path,
            shard_index=3,
            shard_total=8,
            exit_code=exit_code,
            run=mod.RunIdentity(run_id="42", run_attempt="2", sha=SHA),
        ),
    )


def _manifests(
    root: Path,
    mod: ModuleType,
    indexes: list[int],
    total: int,
    **run: str,
) -> None:
    """Write a valid manifest for each shard index under ``root``."""
    for index in indexes:
        shard = root / f"shell-coverage-shard-{index}"
        shard.mkdir(parents=True)
        body = json.dumps({**_doc(mod, index, total), **run})
        (shard / mod.MANIFEST_NAME).write_text(body, encoding="utf-8")


def _doc(mod: ModuleType, index: object, total: object) -> dict[str, object]:
    """Return a manifest body for ``index`` of ``total``."""
    return {"schema": mod.MANIFEST_SCHEMA, "shard_index": index, "shard_total": total}


def test_tap_teardown_file_failure_is_a_finished_failed_run(
    mod: ModuleType,
) -> None:
    """A teardown_file line is a hook, not a test: it does not inflate the count."""
    summary = mod.parse_tap(BATS_TEARDOWN_FILE_FAILED)

    assert_that((summary.planned, summary.tests)).is_equal_to((1, 1))
    assert_that(summary.hooks).is_equal_to(("teardown_file",))
    assert_that(summary.complete).is_true()


def test_tap_teardown_file_line_does_not_fill_a_cut_short_plan(
    mod: ModuleType,
) -> None:
    """A teardown_file line never stands in for a test that did not run."""
    summary = mod.parse_tap("1..2\nok 1 a\nnot ok 2 teardown_file failed\n")

    assert_that(summary.tests).is_equal_to(1)
    assert_that(summary.complete).is_false()


def test_tap_teardown_file_number_is_reused_by_the_next_test(
    mod: ModuleType,
) -> None:
    """Bats 1.14 numbers the next file's test with the hook's K again."""
    text = (
        "1..3\nok 1 a\nnot ok 2 teardown_file failed\nok 2 b\nok 3 c\n"
        "# bats warning: Executed 4 instead of expected 3 tests\n"
    )

    assert_that(mod.parse_tap(text).complete).is_true()


def test_tap_leaked_nested_ok_lines_do_not_count(mod: ModuleType) -> None:
    """Leaked ``ok 1`` / ``1..1`` lines mid-stream; the shard still finishes."""
    text = (
        "1..3\nok 1 a\nok 1 mocked == *--allow-empty-suite* ]]\n1..1\n"
        "ok 1 mocked\nnot ok 1 nested\nok 2 b\nok 1 again\nok 3 c\n"
    )

    summary = mod.parse_tap(text)

    assert_that((summary.planned, summary.tests)).is_equal_to((3, 3))
    assert_that((summary.passed, summary.failed)).is_equal_to((3, 0))
    assert_that(summary.complete).is_true()


def test_tap_leaked_large_number_cannot_fill_a_gap(mod: ModuleType) -> None:
    """A leaked ``ok 4`` (or ``ok 99``) after ``ok 2`` does not reach N."""
    text = "1..4\nok 1 a\nok 2 b\nok 4 leaked\nok 99 leaked\n"

    summary = mod.parse_tap(text)

    assert_that(summary.tests).is_equal_to(2)
    assert_that(summary.shortfall()).is_equal_to(
        f"2 of 4 planned tests have a result {HOOK}",
    )


def test_tap_noise_before_the_plan_is_ignored(mod: ModuleType) -> None:
    """Results before the plan line are noise; counting starts at the plan."""
    text = "raw: true\nok 1 noise\nok 2 noise\n1..2\nok 1 a\nok 2 b\n"

    summary = mod.parse_tap(text)

    assert_that((summary.planned, summary.tests)).is_equal_to((2, 2))
    assert_that(summary.complete).is_true()


@pytest.mark.parametrize(
    "text",
    [
        pytest.param(
            "1..2\nok 1 a\n# Received SIGINT, aborting ...\nok 2 b\n",
            id="leaked-marker-mid-stream",
        ),
        pytest.param(
            _tap(2, 2) + "# Received SIGINT, aborting ...\n",
            id="leaked-marker-at-the-end",
        ),
    ],
)
def test_tap_leaked_sig_marker_does_not_fail_a_finished_shard(
    mod: ModuleType,
    text: str,
) -> None:
    """Shard 6 of run 43402629406: a mocked SIGINT marker leaked in; complete."""
    assert_that(mod.parse_tap(text).complete).is_true()


def test_tap_real_shard_with_leaked_nested_tap(mod: ModuleType) -> None:
    """Regression: trimmed shard-0 TAP of run 43401834823 (808 lines, 1..794)."""
    text = SHARD_FIXTURE.read_text(encoding="utf-8")

    summary = mod.parse_tap(text)

    assert_that((summary.planned, summary.tests)).is_equal_to((794, 794))
    assert_that(summary.complete).is_true()


@pytest.mark.parametrize(
    ("text", "shortfall"),
    [
        pytest.param(
            BATS_SETUP_FILE_FAILED,
            f"0 of 3 planned tests have a result {HOOK}",
            id="setup-file-failure-uninterrupted",
        ),
        pytest.param(
            BATS_SIGTERM,
            f"0 of 4 planned tests have a result {HOOK}",
            id="sigterm-exec-file",
        ),
        pytest.param(
            BATS_SIGINT,
            f"0 of 4 planned tests have a result {HOOK}",
            id="sigint",
        ),
    ],
)
def test_tap_shortfall_is_incomplete(
    mod: ModuleType,
    text: str,
    shortfall: str,
) -> None:
    """Fail closed: any shortfall or trailing marker is incomplete."""
    summary = mod.parse_tap(text)

    assert_that(summary.complete).is_false()
    assert_that(summary.shortfall()).is_equal_to(shortfall)


@pytest.mark.parametrize(
    "text",
    [
        pytest.param(BATS_SETUP_FILE_FAILED, id="setup-file-failure"),
        pytest.param(BATS_SIGTERM, id="sigterm-exec-file"),
        pytest.param(BATS_SIGINT, id="sigint"),
    ],
)
def test_write_manifest_refuses_a_shortfall(
    mod: ModuleType,
    tmp_path: Path,
    text: str,
) -> None:
    """Bats exit 1 with a shortfall writes no manifest, whatever the cause."""
    coverage_dir, tap_path = _shard(tmp_path, tap=text)

    with pytest.raises(mod.IncompleteShardError, match="TAP did not finish"):
        _write(mod, coverage_dir, tap_path, exit_code=1)

    assert_that((coverage_dir / "shard-complete.json").exists()).is_false()


def test_write_manifest_for_the_real_leaky_shard(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """The real shard-0 TAP finishes and writes its manifest (794 tests)."""
    text = SHARD_FIXTURE.read_text(encoding="utf-8")
    coverage_dir, tap_path = _shard(tmp_path, tap=text)

    doc = json.loads(_write(mod, coverage_dir, tap_path, 0).read_text("utf-8"))

    assert_that(doc).contains_entry({"plan": 794})
    assert_that(doc["counts"]).contains_entry({"total": 794})


def test_tap_plan_with_fewer_results_is_incomplete(mod: ModuleType) -> None:
    """A ``1..10`` plan with 4 results is flagged incomplete."""
    summary = mod.parse_tap(_tap(planned=10, results=4))

    assert_that(summary.planned).is_equal_to(10)
    assert_that(summary.tests).is_equal_to(4)
    assert_that(summary.complete).is_false()


def test_tap_counts_skips_failures_and_ignores_indented_output(
    mod: ModuleType,
) -> None:
    """Skips and failures count; indented test output and later plans do not."""
    text = (
        "1..3\n"
        "ok 1 a\n"
        "not ok 2 b\n"
        "# 1..9\n"
        "#   ok 1 nested\n"
        "ok 3 c # skip reason\n"
        "1..7\n"
    )
    summary = mod.parse_tap(text)

    assert_that(summary.planned).is_equal_to(3)
    assert_that((summary.passed, summary.failed, summary.skipped)).is_equal_to(
        (1, 1, 1),
    )
    assert_that(summary.complete).is_true()


def test_tap_without_plan_is_not_complete(mod: ModuleType) -> None:
    """No ``1..N`` line means completion cannot be proven."""
    summary = mod.parse_tap("ok 1 a\n")

    assert_that(summary.planned).is_none()
    assert_that(summary.complete).is_false()


def test_write_manifest_on_complete_run(mod: ModuleType, tmp_path: Path) -> None:
    """A finished shard writes its index, plan, counts and line totals."""
    coverage_dir, tap_path = _shard(tmp_path, tap=_tap(planned=4, results=4))

    path = _write(mod, coverage_dir, tap_path, exit_code=0)

    assert_that(path).is_equal_to(coverage_dir / "shard-complete.json")
    doc = json.loads(path.read_text(encoding="utf-8"))
    assert_that(doc).contains_entry({"shard_index": 3}, {"shard_total": 8})
    assert_that(doc).contains_entry({"plan": 4}, {"lines_covered": 3})
    assert_that(doc).contains_entry({"lines_valid": 6}, {"empty": False})
    assert_that(doc["counts"]).is_equal_to(
        {"passed": 4, "failed": 0, "skipped": 0, "total": 4},
    )


def test_write_manifest_counts_a_failing_but_finished_run(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """bats exit 1 (a failed test) still finished every planned test."""
    tap = "1..2\nok 1 a\nnot ok 2 b\n"
    coverage_dir, tap_path = _shard(tmp_path, tap=tap)

    path = _write(mod, coverage_dir, tap_path, exit_code=1)

    counts = json.loads(path.read_text(encoding="utf-8"))["counts"]
    assert_that(counts["failed"]).is_equal_to(1)


@pytest.mark.parametrize(
    ("tap", "exit_code", "report", "reason"),
    [
        pytest.param(_tap(10, 4), 0, COBERTURA, "4 of 10 planned", id="cut-short"),
        pytest.param("ok 1 a\n", 0, COBERTURA, "no 1..N plan", id="no-plan"),
        pytest.param(_tap(2, 2), 124, COBERTURA, "exited 124", id="timeout"),
        pytest.param(_tap(2, 2), 143, COBERTURA, "exited 143", id="signal"),
        pytest.param(_tap(2, 2), 0, None, "no Cobertura report", id="no-report"),
        pytest.param(
            _tap(2, 2),
            0,
            '<coverage line-rate="0"',
            "no lines-covered",
            id="truncated-report",
        ),
    ],
)
def test_write_manifest_refuses_unfinished_shard(
    mod: ModuleType,
    tmp_path: Path,
    tap: str,
    exit_code: int,
    report: str | None,
    reason: str,
) -> None:
    """No manifest for a cut-short, killed or report-less shard."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    coverage_dir, tap_path = _shard(tmp_path, tap=tap, report=report)
    stale = coverage_dir / "shard-complete.json"
    stale.write_text("{}", encoding="utf-8")

    with pytest.raises(mod.IncompleteShardError, match=reason):
        _write(mod, coverage_dir, tap_path, exit_code=exit_code)

    assert_that(stale.exists()).is_false()


def test_write_manifest_for_empty_shard(mod: ModuleType, tmp_path: Path) -> None:
    """An empty shard (``1..0`` and EMPTY_SHARD) finishes with zero lines."""
    coverage_dir, tap_path = _shard(tmp_path, tap="1..0\n", report=None)
    (coverage_dir / "EMPTY_SHARD").write_text("shard=3/8\n", encoding="utf-8")

    path = _write(mod, coverage_dir, tap_path, exit_code=0)
    doc = json.loads(path.read_text(encoding="utf-8"))

    assert_that(doc).contains_entry({"empty": True}, {"plan": 0})
    assert_that(doc).contains_entry({"lines_valid": 0})


def test_missing_shards_reports_two_of_eight(mod: ModuleType, tmp_path: Path) -> None:
    """8 expected shards with 2 manifests missing is incomplete."""
    _manifests(tmp_path, mod, [0, 1, 2, 5, 6, 7], total=8)

    missing = mod.missing_shards(tmp_path, 8)

    assert_that(missing).is_equal_to([3, 4])
    assert_that(mod.incomplete_reason(missing)).is_equal_to(REASON)


def test_incomplete_reason_names_counts_from_the_shard_taps(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """With the TAP artifacts the reason gives each missing shard's counts."""
    for index, text in ((3, BATS_SIGTERM), (4, _tap(2, 2))):
        folder = tmp_path / f"shell-test-results-pr-shard-{index}"
        folder.mkdir()
        (folder / "bats-output.tap").write_text(text, encoding="utf-8")

    reason = mod.incomplete_reason([3, 4, 5], tmp_path)

    assert_that(reason).is_equal_to(
        "incomplete coverage: shard(s) 3, 4, 5 did not finish: "
        f"shard 3: 0 of 4 planned tests have a result {HOOK}; "
        "shard 4: all 2 planned tests have a result, but no completion "
        "manifest (killed, timed out or no coverage report); "
        "shard 5: no TAP output",
    )


def test_manifest_records_the_run(mod: ModuleType, tmp_path: Path) -> None:
    """The manifest carries run ID, attempt and SHA."""
    coverage_dir, tap_path = _shard(tmp_path, tap=_tap(planned=1, results=1))

    doc = json.loads(_write(mod, coverage_dir, tap_path, 0).read_text("utf-8"))

    assert_that(doc).contains_entry({"run_id": "42"}, {"run_attempt": "2"})
    assert_that(doc).contains_entry({"sha": SHA})


@pytest.mark.parametrize(
    ("manifest_run", "missing"),
    [
        pytest.param({"run_id": "41", "sha": SHA}, [1], id="different-run-id"),
        pytest.param({"run_id": "42", "sha": "ffff"}, [1], id="different-sha"),
        pytest.param({"sha": SHA}, [1], id="no-run-id"),
        pytest.param(
            {"run_id": "42", "run_attempt": "1", "sha": SHA},
            [],
            id="earlier-attempt-same-run",
        ),
    ],
)
def test_missing_shards_checks_the_run(
    mod: ModuleType,
    tmp_path: Path,
    manifest_run: dict[str, str],
    missing: list[int],
) -> None:
    """Another run ID or SHA is missing; an earlier attempt is accepted."""
    run = mod.RunIdentity(run_id="42", run_attempt="2", sha=SHA)
    _manifests(tmp_path, mod, [0], total=2, run_id="42", run_attempt="2", sha=SHA)
    _manifests(tmp_path, mod, [1], total=2, **manifest_run)

    assert_that(mod.missing_shards(tmp_path, 2, run)).is_equal_to(missing)


def test_missing_shards_empty_when_all_present(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """Every shard has a manifest: nothing is missing."""
    _manifests(tmp_path, mod, list(range(8)), total=8)

    assert_that(mod.missing_shards(tmp_path, 8)).is_empty()


def test_missing_shards_ignores_invalid_manifests(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """Wrong total, out-of-range index, bad schema or JSON vouch for nothing."""
    _manifests(tmp_path, mod, [0], total=2)
    bad = {
        "wrong-total": _doc(mod, 1, 3),
        "bool-index": _doc(mod, True, 2),
        "out-of-range": _doc(mod, 2, 2),
        "other-schema": {**_doc(mod, 1, 2), "schema": "x"},
    }
    for name, doc in bad.items():
        (tmp_path / name).mkdir()
        target = tmp_path / name / mod.MANIFEST_NAME
        target.write_text(json.dumps(doc), encoding="utf-8")
    (tmp_path / "garbage").mkdir()
    (tmp_path / "garbage" / mod.MANIFEST_NAME).write_text("{not json", encoding="utf-8")

    assert_that(mod.missing_shards(tmp_path, 2)).is_equal_to([1])


def test_missing_shards_all_missing_without_directory(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """No downloaded artifacts at all: every shard is missing."""
    assert_that(mod.missing_shards(tmp_path / "absent", 3)).is_equal_to([0, 1, 2])


def test_cli_check_exit_codes(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``check`` prints the reason and exits 1 when incomplete, else 0."""
    _manifests(tmp_path, mod, [0, 1, 2, 5, 6, 7], total=8)
    argv = ["check", "--dir", str(tmp_path), "--expected", "8"]

    assert_that(mod.main(argv)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("shard(s) 3, 4 did not finish")

    _manifests(tmp_path / "rest", mod, [3, 4], total=8)
    assert_that(mod.main(argv)).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_empty()

    assert_that(mod.main([*argv, "--run-id", "42", "--sha", SHA])).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("shard(s) 0, 1, 2, 3, 4")


def test_cli_write_warns_and_exits_1_when_unfinished(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``write`` on a cut-short shard warns and writes nothing."""
    coverage_dir, tap_path = _shard(tmp_path, tap=_tap(planned=10, results=4))
    argv = [
        "write",
        "--coverage-dir",
        str(coverage_dir),
        "--tap",
        str(tap_path),
        "--shard-index",
        "3",
        "--shard-total",
        "8",
        "--exit-code",
        "0",
    ]

    assert_that(mod.main(argv)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "::warning::shard 3/8 did not finish",
    )
    assert_that((coverage_dir / "shard-complete.json").exists()).is_false()
