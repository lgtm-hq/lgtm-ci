# SPDX-License-Identifier: MIT
"""Tests for the workflow steps that record and publish BATS durations."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
import yaml
from assertpy import assert_that

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
MAIN_ONLY = (
    "github.event_name == 'push' && github.ref == "
    "format('refs/heads/{0}', github.event.repository.default_branch) "
    "&& !github.event.repository.fork"
)


def _steps(workflow: str, job: str) -> list[dict[str, Any]]:
    """Return one job's steps of a workflow file."""
    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    document = yaml.safe_load(text)
    steps: list[dict[str, Any]] = document["jobs"][job]["steps"]
    return steps


def _by_name(steps: list[dict[str, Any]], name: str) -> tuple[int, dict[str, Any]]:
    """Return a step and its position."""
    for index, step in enumerate(steps):
        if step.get("name") == name:
            return index, step
    raise AssertionError(f"no step {name!r}")


def _condition(step: dict[str, Any]) -> str:
    """Return a step's if: with whitespace collapsed."""
    return " ".join(str(step["if"]).split())


@pytest.mark.parametrize(
    "workflow",
    ["reusable-test-shell.yml", "reusable-test-shell-run.yml"],
)
def test_shard_step_is_best_effort_and_main_only(workflow: str) -> None:
    """The shard step runs on default-branch pushes and cannot fail the shard."""
    steps = _steps(workflow, "test-sharded")
    record_at, record = _by_name(steps, "Record shard BATS durations")
    upload_at, upload = _by_name(steps, "Upload test results")
    recheck_at, _recheck = _by_name(steps, "Recheck harden-runner agent")

    assert_that(_condition(record)).contains(MAIN_ONLY).contains("!cancelled()")
    assert_that(record["continue-on-error"]).is_true()
    assert_that(record["run"]).contains("bats-durations.py").contains(" shard ")
    for argument in (
        '--run-attempt "$GITHUB_RUN_ATTEMPT"',
        '--sha "$GITHUB_SHA"',
        "--filter-marker bats-filter-used.txt",
        "--wall-ms-file bats-duration-ms.txt",
        "--bats-version-file bats-version.txt",
    ):
        assert_that(record["run"]).contains(argument)
    assert_that(record["run"]).does_not_contain("${{")
    assert_that(record["env"]).does_not_contain_key("TEST_FILTER")
    assert_that(record_at).is_less_than(upload_at)
    assert_that(recheck_at).is_equal_to(len(steps) - 1)
    assert_that(upload["with"]["path"]).contains("/bats-durations-shard.json")


@pytest.mark.parametrize(
    "workflow",
    ["reusable-test-shell.yml", "reusable-test-shell-run.yml"],
)
def test_aggregate_publishes_durations_on_main_only(workflow: str) -> None:
    """Merge and upload: main only, best effort, stable name, 90 days."""
    steps = _steps(workflow, "aggregate")
    merge_at, merge = _by_name(steps, "Merge shard BATS durations")
    upload_at, upload = _by_name(steps, "Upload BATS durations")
    warn_at, warn = _by_name(steps, "Warn on failed BATS durations upload")
    download_at, _download = _by_name(steps, "Finalize shard TAP download")
    recheck_at, _recheck = _by_name(steps, "Recheck harden-runner agent")

    assert_that(_condition(merge)).contains(MAIN_ONLY)
    assert_that(merge["continue-on-error"]).is_true()
    assert_that(merge["run"]).contains('--run-attempt "$GITHUB_RUN_ATTEMPT"')
    assert_that(merge["run"]).does_not_contain("${{")
    assert_that(upload["continue-on-error"]).is_true()
    assert_that(upload["if"]).contains("steps.durations.outcome == 'success'")
    assert_that(upload["with"]["name"]).is_equal_to(
        "${{ inputs.artifact-prefix }}-bats-durations",
    )
    assert_that(upload["with"]["retention-days"]).is_equal_to(90)
    assert_that(upload["with"]["path"]).ends_with("/bats-durations.json")
    assert_that(warn["if"]).contains("steps.upload-durations.outcome == 'failure'")
    assert_that([download_at, merge_at, upload_at, warn_at, recheck_at]).is_sorted()
    assert_that(recheck_at).is_equal_to(len(steps) - 1)
