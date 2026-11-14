# SPDX-License-Identifier: MIT
"""Shard artifact download retry and download-failure reporting (#1562).

A transient download error in the shell-tests aggregate (``ECONNRESET`` on
``GetSignedArtifactURL``) used to surface as "shard(s) N did not finish",
though the shard had finished. The aggregate now retries each shard download
a bounded number of times and passes the final outcome to the completeness
check, which reports a failed download as such.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any, NamedTuple

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/actions/shard-completion.py"
WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
WORKFLOW_FILES = ["reusable-test-shell.yml", "reusable-test-shell-run.yml"]
SHA = "0123abcd"
DOWNLOAD_ACTION = "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333"
PATTERN = "shell-coverage-shell-test-results-shard-*"
DID_NOT_FINISH = "did not finish (cancelled or timed out; no completion manifest)"
DOWNLOAD_FAILED = f"artifact download failed for {PATTERN}"
RESET_SCRIPT = r"\.lgtm-ci-tooling/scripts/ci/actions/shard-download\.sh"

# kind -> (first attempt id, pattern infix, download path suffix)
KINDS = {
    "taps": ("download-taps", "test-results", "shard-taps"),
    "coverage": ("download-coverage", "coverage", "shard-coverage"),
}


@pytest.fixture(name="mod")
def fixture_mod(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the hyphenated script as a module."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="evaluator")
def fixture_evaluator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the repo's Actions expression evaluator."""
    return load_script("tests/helpers/gha_expr.py")


def _manifests(root: Path, mod: ModuleType, indexes: list[int], total: int) -> None:
    """Write a valid manifest of this run for each shard index under ``root``."""
    for index in indexes:
        shard = root / f"shell-coverage-shard-{index}"
        shard.mkdir(parents=True)
        body = {
            "schema": mod.MANIFEST_SCHEMA,
            "shard_index": index,
            "shard_total": total,
            "run_id": "42",
            "sha": SHA,
        }
        (shard / mod.MANIFEST_NAME).write_text(json.dumps(body), encoding="utf-8")


def _check(mod: ModuleType, root: Path, outcome: str | None) -> int:
    """Run ``check`` for 4 shards of run 42, with an optional download outcome."""
    argv = ["check", "--dir", str(root), "--expected", "4"]
    argv += ["--run-id", "42", "--sha", SHA]
    if outcome is not None:
        argv += ["--download-outcome", outcome, "--artifact-pattern", PATTERN]
    result: int = mod.main(argv)
    return result


def _aggregate_steps(workflow: str) -> list[dict[str, Any]]:
    """Return the ``aggregate`` job's steps of a workflow file."""
    doc = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8"))
    steps: list[dict[str, Any]] = doc["jobs"]["aggregate"]["steps"]
    return steps


def _by_id(steps: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Index steps by id."""
    return {step["id"]: step for step in steps if "id" in step}


def _pattern(infix: str) -> str:
    """Return the workflow's artifact pattern expression for ``infix``."""
    prefix = "${{ inputs.artifact-prefix }}"
    marker = "${{ inputs.comment-marker }}"
    return f"{prefix}-{infix}-{marker}-shard-*"


def _final_outcome(first: str) -> str:
    """Return the expression every consumer reads the folded outcome from."""
    return f"${{{{ steps.{first}-final.outputs.outcome || 'failure' }}}}"


class CheckCase(NamedTuple):
    """One `check` scenario: download outcome, shards present, result."""

    outcome: str | None
    present: list[int]
    code: int
    expected: str
    absent: str


# --- check: the download outcome decides which reason is printed ----------


@pytest.mark.parametrize(
    "case",
    [
        pytest.param(
            CheckCase(
                "failure",
                [0, 1, 3],
                1,
                f"{DOWNLOAD_FAILED} (download outcome 'failure' after retries",
                DID_NOT_FINISH,
            ),
            id="download-failed-names-download-not-shard",
        ),
        pytest.param(
            CheckCase(
                "failure",
                [0, 1, 2, 3],
                1,
                DOWNLOAD_FAILED,
                DID_NOT_FINISH,
            ),
            id="download-failed-fails-closed-even-when-complete",
        ),
        pytest.param(
            CheckCase(
                "skipped",
                [],
                1,
                "download outcome 'skipped'",
                DID_NOT_FINISH,
            ),
            id="download-skipped-is-a-failure",
        ),
        pytest.param(
            CheckCase(
                "success",
                [0, 1, 3],
                1,
                f"shard(s) 2 {DID_NOT_FINISH}",
                "download failed",
            ),
            id="downloaded-but-no-manifest",
        ),
        pytest.param(
            CheckCase(
                None,
                [0, 1, 3],
                1,
                f"shard(s) 2 {DID_NOT_FINISH}",
                "download failed",
            ),
            id="no-outcome-keeps-the-old-reason",
        ),
    ],
)
def test_check_reason_follows_download_outcome(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    case: CheckCase,
) -> None:
    """A failed download is reported as one, never as an unfinished shard."""
    _manifests(tmp_path, mod, case.present, total=4)

    assert_that(_check(mod, tmp_path, case.outcome)).is_equal_to(case.code)
    out = capsys.readouterr().out
    assert_that(out).contains(case.expected)
    assert_that(out).does_not_contain(case.absent)


def test_check_download_failure_names_unverified_shards(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The download reason still lists the shards it could not verify."""
    _manifests(tmp_path, mod, [0, 3], total=4)

    _check(mod, tmp_path, "failure")

    assert_that(capsys.readouterr().out.strip()).ends_with("; shard(s) 1, 2 unverified")


@pytest.mark.parametrize("outcome", ["success", None])
def test_check_passes_when_downloaded_and_complete(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    outcome: str | None,
) -> None:
    """Every manifest present after a successful download passes."""
    _manifests(tmp_path, mod, [0, 1, 2, 3], total=4)

    assert_that(_check(mod, tmp_path, outcome)).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_empty()


# --- workflow: bounded retry steps and outcome wiring ---------------------


@pytest.mark.parametrize("workflow", WORKFLOW_FILES)
@pytest.mark.parametrize("kind", sorted(KINDS))
def test_download_has_two_bounded_retries(workflow: str, kind: str) -> None:
    """Three pinned attempts, each retry gated on the previous attempt failing."""
    first, infix, path = KINDS[kind]
    steps = _aggregate_steps(workflow)
    by_id = _by_id(steps)
    ids = [first, f"{first}-retry-1", f"{first}-retry-2"]
    pattern = _pattern(infix)

    assert_that(by_id[first]["if"]).is_equal_to("always()")
    for previous, attempt in zip(ids, ids[1:], strict=False):
        assert_that(by_id[attempt]["if"]).is_equal_to(
            f"always() && steps.{previous}.outcome == 'failure'",
        )
    for attempt in ids:
        step = by_id[attempt]
        assert_that(step["uses"]).is_equal_to(DOWNLOAD_ACTION)
        assert_that(step["continue-on-error"]).is_true()
        assert_that(step["with"]).contains_entry(
            {"pattern": pattern},
            {"path": f"${{{{ runner.temp }}}}/{path}"},
            {"merge-multiple": False},
        )

    positions = [steps.index(by_id[attempt]) for attempt in ids]
    assert_that(positions).is_sorted()
    for previous, attempt in zip(ids, ids[1:], strict=False):
        backoff = steps[steps.index(by_id[attempt]) - 1]
        assert_that(backoff["if"]).is_equal_to(by_id[attempt]["if"])
        # The back-off also empties the destination (#1562): the pinned action
        # extracts a lone match into the root, beside an earlier attempt's dirs.
        assert_that(backoff["env"]).contains_entry(
            {"DOWNLOAD_DIR": f"${{{{ runner.temp }}}}/{path}"},
        )
        assert_that(backoff["run"]).matches(
            rf'^bash {RESET_SCRIPT}\s+reset "\$DOWNLOAD_DIR" [1-9][0-9]*$',
        )
        assert_that(steps.index(backoff)).is_greater_than(steps.index(by_id[previous]))


@pytest.mark.parametrize("workflow", WORKFLOW_FILES)
@pytest.mark.parametrize("kind", sorted(KINDS))
def test_finalize_step_folds_attempts_once(workflow: str, kind: str) -> None:
    """One finalize step per family runs after the last attempt, before any reader."""
    first, _infix, path = KINDS[kind]
    steps = _aggregate_steps(workflow)
    by_id = _by_id(steps)
    final = by_id[f"{first}-final"]

    assert_that(final["if"]).is_equal_to("always()")
    assert_that(final["env"]).contains_entry(
        {"DOWNLOAD_DIR": f"${{{{ runner.temp }}}}/{path}"},
        {"DOWNLOAD_OUTCOME": f"${{{{ steps.{first}.outcome }}}}"},
        {"DOWNLOAD_RETRY_1_OUTCOME": f"${{{{ steps.{first}-retry-1.outcome }}}}"},
        {"DOWNLOAD_RETRY_2_OUTCOME": f"${{{{ steps.{first}-retry-2.outcome }}}}"},
    )
    assert_that(final["run"]).matches(
        rf'^bash {RESET_SCRIPT}\s+finalize "\$DOWNLOAD_DIR"$',
    )
    position = steps.index(final)
    assert_that(position).is_greater_than(steps.index(by_id[f"{first}-retry-2"]))
    assert_that(position).is_less_than(steps.index(by_id["results"]))
    # The attempts are folded only here, so no consumer can drift from it.
    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    assert_that(text.count(f"{first}-retry-2.outcome")).is_equal_to(1)
    # Layout detection is by content (shard-complete.json), never by pattern:
    # bash globs do not reproduce the action's minimatch.
    assert_that(final["env"]).does_not_contain_key("DOWNLOAD_PATTERN")


@pytest.mark.parametrize("workflow", WORKFLOW_FILES)
def test_checks_read_the_final_download_outcome(workflow: str) -> None:
    """aggregate-results and merge-coverage get the folded outcomes and patterns."""
    by_id = _by_id(_aggregate_steps(workflow))
    coverage = _final_outcome("download-coverage")
    coverage_pattern = _pattern("coverage")

    results = by_id["results"]["env"]
    assert_that(results).contains_entry(
        {"SHARD_ARTIFACTS_DOWNLOAD_OUTCOME": _final_outcome("download-taps")},
        {"SHARD_COVERAGE_DOWNLOAD_OUTCOME": coverage},
        {"SHARD_COVERAGE_PATTERN": coverage_pattern},
    )
    assert_that(results["SHARD_ARTIFACTS_PATTERN"]).contains("-test-results-")
    merge = by_id["merge"]["env"]
    assert_that(merge).contains_entry(
        {"SHARD_COVERAGE_DOWNLOAD_OUTCOME": coverage},
        {"SHARD_COVERAGE_PATTERN": coverage_pattern},
    )


@pytest.mark.parametrize(
    ("output", "final"),
    [
        pytest.param("success", "success", id="finalized-success"),
        pytest.param("failure", "failure", id="finalized-failure"),
        pytest.param("", "failure", id="finalize-crashed-fails-closed"),
    ],
)
def test_consumers_fail_closed_without_a_folded_outcome(
    evaluator: ModuleType,
    output: str,
    final: str,
) -> None:
    """A finalize step that wrote no outcome reads as a failed download."""
    context = {"steps.download-coverage-final.outputs.outcome": output}
    rendered = evaluator.render(_final_outcome("download-coverage"), context)

    assert_that(rendered).is_equal_to(final)
