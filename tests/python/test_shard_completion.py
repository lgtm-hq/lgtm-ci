# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/actions/shard-completion.py`` (#1531).

A shard writes ``shard-complete.json`` from its own workflow step, gated on
GitHub step state (not cancelled, an ``exit-code`` output other than 124);
the aggregate merges coverage and publishes totals only when every expected
shard of this run and commit has one.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/actions/shard-completion.py"
WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
COBERTURA = (
    '<?xml version="1.0" ?>\n'
    '<coverage line-rate="0.5" lines-covered="3" lines-valid="6" version="1">\n'
    "</coverage>\n"
)
SHA = "0123abcd"
REASON = (
    "incomplete coverage: shard(s) 3, 4 did not finish "
    "(cancelled or timed out; no completion manifest)"
)
GATE = (
    "${{ !cancelled() && steps.coverage-run.outputs.exit-code != '' "
    "&& steps.coverage-run.outputs.exit-code != '124' "
    "&& steps.coverage-run.outputs.interrupted != 'true' }}"
)


@pytest.fixture(name="mod")
def fixture_mod(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the hyphenated script as a module."""
    return load_script(SCRIPT_PATH)


def _coverage_dir(root: Path, report: str | None = COBERTURA) -> Path:
    """Lay out one shard's kcov output directory."""
    coverage_dir = root / "coverage-report"
    (coverage_dir / "kcov-merged").mkdir(parents=True)
    if report is not None:
        target = coverage_dir / "kcov-merged" / "cov.xml"
        target.write_text(report, encoding="utf-8")
    return coverage_dir


def _write(mod: ModuleType, coverage_dir: Path, exit_code: int) -> Path:
    """Call ``write_manifest`` for shard 3 of 8 of run 42, attempt 2."""
    return Path(
        mod.write_manifest(
            coverage_dir=coverage_dir,
            shard=mod.ShardRef(index=3, total=8),
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


def _steps(name: str) -> list[dict[str, Any]]:
    """Return the ``test-sharded`` job's steps of a workflow file."""
    doc = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
    steps: list[dict[str, Any]] = doc["jobs"]["test-sharded"]["steps"]
    return steps


@pytest.mark.parametrize("exit_code", [0, 1], ids=["passing", "failing-tests"])
def test_write_manifest_for_a_finished_shard(
    mod: ModuleType,
    tmp_path: Path,
    exit_code: int,
) -> None:
    """Exit 0 and exit 1 (failing tests) both finished: manifest written."""
    path = _write(mod, _coverage_dir(tmp_path), exit_code)

    doc = json.loads(path.read_text(encoding="utf-8"))
    assert_that(doc).contains_entry({"shard_index": 3}, {"shard_total": 8})
    assert_that(doc).contains_entry({"lines_covered": 3}, {"lines_valid": 6})
    assert_that(doc).contains_entry({"exit_code": exit_code}, {"empty": False})
    assert_that(doc).contains_entry({"run_id": "42"}, {"run_attempt": "2"})
    assert_that(doc).contains_entry({"sha": SHA})


@pytest.mark.parametrize(
    ("exit_code", "report", "reason"),
    [
        pytest.param(124, COBERTURA, "exited 124", id="timeout"),
        pytest.param(143, COBERTURA, "exited 143", id="signal"),
        pytest.param(0, None, "no Cobertura report", id="no-report"),
        pytest.param(
            0,
            '<coverage line-rate="0"',
            "no lines-covered",
            id="truncated-report",
        ),
    ],
)
def test_write_manifest_refuses_an_unfinished_shard(
    mod: ModuleType,
    tmp_path: Path,
    exit_code: int,
    report: str | None,
    reason: str,
) -> None:
    """A timeout, a kill or a missing report writes nothing (stale removed)."""
    coverage_dir = _coverage_dir(tmp_path, report)
    stale = coverage_dir / "shard-complete.json"
    stale.write_text("{}", encoding="utf-8")

    with pytest.raises(mod.IncompleteShardError, match=reason):
        _write(mod, coverage_dir, exit_code)

    assert_that(stale.exists()).is_false()


def test_write_manifest_for_empty_shard(mod: ModuleType, tmp_path: Path) -> None:
    """An empty shard (EMPTY_SHARD, no report) finishes with zero lines."""
    coverage_dir = _coverage_dir(tmp_path, report=None)
    (coverage_dir / "EMPTY_SHARD").write_text("shard=3/8\n", encoding="utf-8")

    doc = json.loads(_write(mod, coverage_dir, 0).read_text(encoding="utf-8"))

    assert_that(doc).contains_entry({"empty": True}, {"lines_valid": 0})


@pytest.mark.parametrize(
    "workflow",
    ["reusable-test-shell.yml", "reusable-test-shell-run.yml"],
)
def test_workflow_gates_the_manifest_on_step_state(workflow: str) -> None:
    """Not cancelled, an exit-code output, not 124; before the uploads."""
    steps = _steps(workflow)
    names = [step.get("name", "") for step in steps]
    record = steps[names.index("Record shard completion")]

    assert_that(" ".join(record["if"].split())).is_equal_to(GATE)
    assert_that(record["env"]).contains_entry({"STEP": "shard-manifest"})
    assert_that(record["env"]["EXIT_CODE"]).is_equal_to(
        "${{ steps.coverage-run.outputs.exit-code }}",
    )
    assert_that(record["env"]["INTERRUPTED"]).is_equal_to(
        "${{ steps.coverage-run.outputs.interrupted }}",
    )
    assert_that(names.index("Record shard completion")).is_greater_than(
        [step.get("id") for step in steps].index("coverage-run"),
    )
    assert_that(names.index("Record shard completion")).is_less_than(
        names.index("Upload coverage report"),
    )
    assert_that(record["run"].count("\n")).is_less_than_or_equal_to(1)


@pytest.mark.parametrize(
    ("cancelled", "exit_code", "interrupted", "runs"),
    [
        pytest.param(True, "0", "", False, id="cancelled"),
        pytest.param(False, "124", "", False, id="suite-timeout"),
        pytest.param(False, "", "", False, id="job-timeout"),
        pytest.param(False, "0", "true", False, id="step-timeout-kcov-returned"),
        pytest.param(False, "0", "", True, id="passing"),
        pytest.param(False, "1", "", True, id="failing-tests"),
    ],
)
def test_gate_expression_semantics(
    load_script: Callable[[str], ModuleType],
    cancelled: bool,
    exit_code: str,
    interrupted: str,
    runs: bool,
) -> None:
    """Evaluate the gate with the repo's Actions expression evaluator."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    context = {
        # Failing tests leave the job failing, not cancelled; the gate's
        # !cancelled() must still let the step run then.
        "job.status": "cancelled" if cancelled else "failure",
        "steps.coverage-run.outputs.exit-code": exit_code,
        "steps.coverage-run.outputs.interrupted": interrupted,
    }

    assert_that(evaluator.evaluate(GATE, context)).is_equal_to(runs)


def test_missing_shards_reports_two_of_eight(mod: ModuleType, tmp_path: Path) -> None:
    """8 expected shards with 2 manifests missing is incomplete."""
    _manifests(tmp_path, mod, [0, 1, 2, 5, 6, 7], total=8)

    missing = mod.missing_shards(tmp_path, 8)

    assert_that(missing).is_equal_to([3, 4])
    assert_that(mod.incomplete_reason(missing)).is_equal_to(REASON)


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
    (tmp_path / "garbage" / mod.MANIFEST_NAME).write_text("{not", encoding="utf-8")

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
    run = {"run_id": "42", "sha": SHA}
    _manifests(tmp_path, mod, [0, 1, 2, 5, 6, 7], total=8, **run)
    argv = ["check", "--dir", str(tmp_path), "--expected", "8"]
    argv += ["--run-id", "42", "--sha", SHA]

    assert_that(mod.main(argv)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("shard(s) 3, 4 did not finish")

    _manifests(tmp_path / "rest", mod, [3, 4], total=8, **run)
    assert_that(mod.main(argv)).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_empty()

    argv[-3] = "41"
    assert_that(mod.main(argv)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("shard(s) 0, 1, 2, 3, 4")


@pytest.mark.parametrize(
    "identity",
    [
        pytest.param([], id="neither"),
        pytest.param(["--run-id", "42"], id="no-sha"),
        pytest.param(["--sha", SHA], id="no-run-id"),
        pytest.param(["--run-id", "", "--sha", ""], id="empty-values"),
    ],
)
def test_cli_check_without_run_identity_is_a_usage_error(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    identity: list[str],
) -> None:
    """Fail closed: no run ID or SHA would accept any run's manifests."""
    _manifests(tmp_path, mod, [0, 1], total=2)
    argv = ["check", "--dir", str(tmp_path), "--expected", "2", *identity]

    with pytest.raises(SystemExit) as exit_info:
        mod.main(argv)

    assert_that(exit_info.value.code).is_equal_to(2)
    assert_that(capsys.readouterr().err).contains("--run-id and --sha are required")


def test_cli_write_warns_and_exits_1_when_unfinished(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``write`` after a suite timeout (124) warns and writes nothing."""
    coverage_dir = _coverage_dir(tmp_path)
    argv = [
        "write",
        "--coverage-dir",
        str(coverage_dir),
        "--shard-index",
        "3",
        "--shard-total",
        "8",
        "--exit-code",
        "124",
    ]

    assert_that(mod.main(argv)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(
        "::warning::shard 3/8 did not finish",
    )
    assert_that((coverage_dir / "shard-complete.json").exists()).is_false()
