# SPDX-License-Identifier: MIT
"""Exercise the experimental observer CLI and its actual caller source."""

import json
import os
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/actions/python_skip_preset_observe.py"
METADATA = {
    "event": "pull_request",
    "repository": "lgtm-hq/lgtm-ci",
    "head_repository": "lgtm-hq/lgtm-ci",
    "head_ref": "proof/1297-preset",
    "head": "a" * 40,
    "sha": "b" * 40,
    "ref": "refs/pull/1305/merge",
    "run_id": "123",
    "attempt": "1",
    "draft": "false",
    "case": "invalid-egress-preset",
}
SOURCE_REPOSITORIES = [
    pytest.param("lgtm-hq/lgtm-ci", True, id="owned"),
    pytest.param("fork-owner/lgtm-ci", False, id="fork-same-branch"),
    pytest.param("", False, id="missing"),
]


def observe(
    tmp_path: Path, raw: str, **metadata: str
) -> tuple[subprocess.CompletedProcess[str], dict[str, Any]]:
    """Run the real CLI with literal Actions-shaped inputs in an empty directory."""
    environment = dict(os.environ, PROOF_NEEDS=raw)
    environment.update(
        {f"PROOF_{key.upper()}": value for key, value in (METADATA | metadata).items()}
    )
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=tmp_path,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    record = json.loads((tmp_path / "python-skip-preset-observation.json").read_text())
    assert record["raw_needs"] == raw
    return result, record


def test_successful_caller_is_rejected(tmp_path: Path) -> None:
    """A successful reusable cannot certify the intentional preset failure."""
    raw = '{ "probe": {"result":"success", "outputs":{}} }'
    result, _ = observe(tmp_path, raw)
    assert result.returncode == 1, result.stdout + result.stderr


@pytest.mark.parametrize("outputs", [{}, {"passed": ""}, {"passed": "false"}])
def test_failure_preserves_absence(tmp_path: Path, outputs: dict[str, str]) -> None:
    """Unknown-preset rejection may precede matrix/output creation."""
    needs = {"probe": {"result": "failure", "outputs": outputs}}
    raw = " \n" + json.dumps(needs, indent=3) + "\n "
    result, record = observe(tmp_path, raw)
    assert result.returncode == 0, result.stdout + result.stderr
    assert record["needs"] == needs
    assert record["metadata"] == METADATA
    assert record["errors"] == []


@pytest.mark.parametrize(
    "needs",
    [
        {"probe": {"result": "cancelled", "outputs": {}}},
        {"probe": {"result": "skipped", "outputs": {}}},
        {"probe": {"result": "failure", "outputs": {"passed": "true"}}},
        {"probe": {"result": "failure", "outputs": {"passed": False}}},
        {"probe": {"result": "failure", "outputs": {"tests-total": 0}}},
        {"probe": {"result": "failure", "outputs": []}},
        {"probe": {"result": False}},
        {"probe": []},
        {},
        [],
        None,
    ],
)
def test_rejected_needs_retained(tmp_path: Path, needs: Any) -> None:
    """Reject invalid shapes/types without altering the observed evidence."""
    raw = json.dumps(needs)
    result, record = observe(tmp_path, raw)
    assert result.returncode == 1
    assert record["needs"] == needs
    assert record["errors"]


def test_malformed_json_retained(tmp_path: Path) -> None:
    """Even undecodable raw needs survive CLI rejection."""
    result, record = observe(tmp_path, '{ "probe": broken')
    assert result.returncode == 1
    assert "needs" not in record
    assert record["errors"]


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("event", "workflow_dispatch"),
        ("event", "push"),
        ("event", "merge_group"),
        ("repository", "other/lgtm-ci"),
        ("head_ref", "main"),
        ("head_ref", "proof/1297-preset-extra"),
        ("draft", "true"),
        ("ref", "refs/heads/proof/1297-preset"),
        ("case", "positive"),
    ],
)
def test_wrong_context_retained(tmp_path: Path, key: str, value: str) -> None:
    """A real ready PR on the exact owned branch is required."""
    raw = '{"probe":{"result":"failure","outputs":{}}}'
    result, record = observe(tmp_path, raw, **{key: value})
    assert result.returncode == 1
    assert record["metadata"][key] == value


def test_absent_outputs_stay_absent(tmp_path: Path) -> None:
    """No output object is manufactured when prepare fails early."""
    needs = {"probe": {"result": "failure"}}
    result, record = observe(tmp_path, json.dumps(needs))
    assert result.returncode == 0
    assert record["needs"] == needs


@pytest.mark.parametrize(("head_repository", "accepted"), SOURCE_REPOSITORIES)
def test_observer_source(tmp_path: Path, head_repository: str, accepted: bool) -> None:
    """The CLI must retain and check the actual PR head repository."""
    raw = '{"probe":{"result":"failure","outputs":{}}}'
    result, record = observe(tmp_path, raw, head_repository=head_repository)
    assert result.returncode == int(not accepted), result.stdout + result.stderr
    assert record["metadata"] == METADATA | {"head_repository": head_repository}
    assert record["needs"] == json.loads(raw)
    assert bool(record["errors"]) is not accepted


def workflow_source(name: str) -> dict[Any, Any]:
    """Read repository workflow source without changing YAML's scalar semantics."""
    path = ROOT / ".github/workflows" / f"{name}.yml"
    workflow: dict[Any, Any] = yaml.safe_load(path.read_text())
    return workflow


def test_workflow_source_contract() -> None:
    """Bind actual guarded PR source, invalid preset and observer to one case."""
    workflow = workflow_source("proof-python-skip-preset")
    assert workflow[True] == {
        "pull_request": {
            "types": ["opened", "synchronize", "reopened", "ready_for_review"],
        },
    }
    assert workflow["permissions"] == {}
    jobs = workflow["jobs"]
    assert set(jobs) == {"probe", "observe"}
    probe = jobs["probe"]
    assert probe["uses"] == (
        "lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml"
        "@761e2f173be08f57f0be18d8332e2b063387d987"
    )
    assert probe["permissions"] == {
        "actions": "read",
        "contents": "read",
        "pull-requests": "write",
    }
    inputs = probe["with"]
    assert inputs == {
        "job-name": "Proof Python Invalid Preset",
        "python-version": "3.12",
        "working-directory": "tests/fixtures/python-skip-proof",
        "test-path": "tests/pass",
        "coverage": False,
        "publish-test-summary": False,
        "artifact-prefix": "proof_invalid_preset",
        "pipeline-skip": True,
        "draft-pr-skip": True,
        "egress-preset": "nonexistent_1297_preset",
        "timeout-minutes": 5,
    }
    production = workflow_source("reusable-test-python")
    presets = json.loads(production["env"]["LGTM_CI_EGRESS_PRESETS"])
    assert inputs["egress-preset"] not in presets
    defaults = production[True]["workflow_call"]["inputs"]
    assert defaults["pipeline-skip"]["default"] is False
    assert defaults["egress-policy"]["default"] == "block"
    observer = jobs["observe"]
    assert observer["needs"] == ["probe"]
    assert observer["timeout-minutes"] == 5
    assert observer["runs-on"] == "${{ vars.LGTM_CI_RUNNER || 'ubuntu-26.04' }}"
    assert observer["permissions"] == {"contents": "read"}
    steps = observer["steps"]
    record = next(step for step in steps if "run" in step)
    assert record["run"] == "python3 scripts/ci/actions/python_skip_preset_observe.py"
    assert record["env"] == {
        "PROOF_NEEDS": "${{ toJSON(needs) }}",
        "PROOF_EVENT": "${{ github.event_name }}",
        "PROOF_REPOSITORY": "${{ github.repository }}",
        "PROOF_HEAD_REPOSITORY": "${{ github.event.pull_request.head.repo.full_name }}",
        "PROOF_HEAD_REF": "${{ github.head_ref }}",
        "PROOF_HEAD": "${{ github.event.pull_request.head.sha }}",
        "PROOF_SHA": "${{ github.sha }}",
        "PROOF_REF": "${{ github.ref }}",
        "PROOF_RUN_ID": "${{ github.run_id }}",
        "PROOF_ATTEMPT": "${{ github.run_attempt }}",
        "PROOF_DRAFT": "${{ github.event.pull_request.draft }}",
        "PROOF_CASE": METADATA["case"],
    }
    canonical = workflow_source("proof-python-skip")["jobs"]["observe"]["steps"]
    assert steps[0] == canonical[0]
    assert steps[1] == canonical[1]
    upload = steps[-1]
    assert upload["uses"] == canonical[-1]["uses"]
    assert upload["if"] == "always()"
    assert upload["with"] == {
        "name": "proof_invalid_preset_observation",
        "path": "python-skip-preset-observation.json",
        "if-no-files-found": "error",
        "retention-days": 7,
    }
    assert all("continue-on-error" not in job for job in jobs.values())
    assert all("continue-on-error" not in step for step in steps)


def test_workflow_guards(load_script: Callable[[str], ModuleType]) -> None:
    """Evaluate real job guards, including observer execution after failure."""
    jobs = workflow_source("proof-python-skip-preset")["jobs"]
    evaluator = load_script("tests/helpers/gha_expr.py")
    context = {
        "github.event_name": "pull_request",
        "github.repository": "lgtm-hq/lgtm-ci",
        "github.event.pull_request.head.repo.full_name": "lgtm-hq/lgtm-ci",
        "github.head_ref": "proof/1297-preset",
    }
    for key, value in (
        ("github.event_name", "push"),
        ("github.event_name", "workflow_dispatch"),
        ("github.event_name", "merge_group"),
        ("github.repository", "other/lgtm-ci"),
        ("github.head_ref", "main"),
        ("github.head_ref", "proof/1297-preset-extra"),
    ):
        for job in jobs.values():
            assert not evaluator.evaluate(job["if"], context | {key: value})
    assert evaluator.evaluate(jobs["probe"]["if"], context)
    assert "always()" in jobs["observe"]["if"]
    failed_context = context | {"job.status": "failure"}
    assert evaluator.evaluate(jobs["observe"]["if"], failed_context)


@pytest.mark.parametrize(("head_repository", "accepted"), SOURCE_REPOSITORIES)
@pytest.mark.parametrize("job_name", ["probe", "observe"])
def test_workflow_source_repository(
    load_script: Callable[[str], ModuleType],
    head_repository: str,
    accepted: bool,
    job_name: str,
) -> None:
    """Both real guards reject a fork or absent source on the same branch."""
    jobs = workflow_source("proof-python-skip-preset")["jobs"]
    evaluator = load_script("tests/helpers/gha_expr.py")
    context = {
        "github.event_name": "pull_request",
        "github.repository": "lgtm-hq/lgtm-ci",
        "github.head_ref": "proof/1297-preset",
    }
    if head_repository:
        context["github.event.pull_request.head.repo.full_name"] = head_repository
    status = "failure" if job_name == "observe" else "success"
    expression = jobs[job_name]["if"]
    assert evaluator.evaluate(expression, context | {"job.status": status}) is accepted
