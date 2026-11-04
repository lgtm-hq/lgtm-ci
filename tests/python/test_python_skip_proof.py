# SPDX-License-Identifier: MIT
"""Local source/observer contracts; these do not prove hosted job names."""

import json
import os
import subprocess
import sys
import tomllib
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import patch

import pytest
import yaml

PROJECT_ROOT = Path(__file__).resolve().parents[2]
FIXTURE = PROJECT_ROOT / "tests/fixtures/python-skip-proof"


@pytest.fixture(name="observer")
def fixture_observer(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Use pytest's loader fixture across nested conftest collection boundaries."""
    return load_script("scripts/ci/actions/python-skip-proof-observe.py")


def delivered(total: str = "0", result: str = "success") -> dict[str, Any]:
    """Create delivered strings, including explicit absence for cancelled jobs."""
    return {
        "result": result,
        "outputs": {
            "tests-passed": total,
            "tests-failed": "0",
            "tests-total": total,
            "coverage-percent": "0",
            "passed": "true",
        },
    }


@pytest.mark.parametrize("event", ["pull_request", "push", "merge_group"])
def test_positive_routes(observer: ModuleType, event: str) -> None:
    """Baseline and PR skips work; non-PR zero counts are rejected."""
    metadata = {"case": "positive", "event": event, "draft": "false"}
    needs = {key: delivered(str(count)) for key, count in observer.COUNTS.items()}
    assert observer.errors_for(needs, metadata) == []
    needs = {key: delivered() for key in observer.COUNTS}
    assert bool(observer.errors_for(needs, metadata)) == (event != "pull_request")


@pytest.mark.parametrize("result", ["failure", "cancelled", "skipped"])
@pytest.mark.parametrize("passed", [None, "", "false", "true"])
def test_negative_outputs(
    observer: ModuleType,
    result: str,
    passed: str | None,
) -> None:
    """Absence stays absent; neither wrong conclusions nor true outputs pass."""
    outputs = {} if passed is None else {"passed": passed}
    needs = {"probe": {"result": result, "outputs": outputs}}
    for case, expected in (("pytest-failure", "failure"), ("cancel", "cancelled")):
        errors = observer.errors_for(needs, {"case": case})
        invalid = case == "pytest-failure" or result != expected or passed == "true"
        assert bool(errors) == invalid
    assert needs["probe"]["outputs"] == outputs


@pytest.mark.parametrize(
    "field",
    [None, "tests-passed", "tests-failed", "tests-total", "passed"],
)
def test_pytest_failure_requires_executed_control(
    observer: ModuleType,
    field: str | None,
) -> None:
    """Require delivered counts from the single selected failing control."""
    outputs = {
        "tests-passed": "0",
        "tests-failed": "1",
        "tests-total": "1",
        "passed": "false",
    }
    if field is not None:
        outputs.pop(field)
    needs = {"probe": {"result": "failure", "outputs": outputs}}
    errors = observer.errors_for(needs, {"case": "pytest-failure"})
    assert bool(errors) == (field is not None)


def test_draft_and_string_contract(observer: ModuleType) -> None:
    """Draft skips cannot claim true; boolean outputs are invalid."""
    metadata = {"case": "positive", "event": "pull_request", "draft": "true"}
    needs: dict[str, Any] = {}
    for key in observer.COUNTS:
        needs[key] = {"result": "skipped", "outputs": {}}
    assert not observer.errors_for(needs, metadata)
    needs["single"]["outputs"]["passed"] = True
    assert observer.errors_for(needs, metadata)


def test_failed_observation_retains_raw(tmp_path: Path) -> None:
    """A failed assertion still writes exact raw input and actual output types."""
    raw = '{ "probe": {"result": "cancelled", "outputs": {}} }'
    result = subprocess.run(
        [
            sys.executable,
            str(PROJECT_ROOT / "scripts/ci/actions/python-skip-proof-observe.py"),
        ],
        cwd=tmp_path,
        env=dict(os.environ, PROOF_NEEDS=raw, PROOF_CASE="pytest-failure"),
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    record = json.loads((tmp_path / "python-skip-proof-observation.json").read_text())
    assert record["raw_needs"] == raw
    assert record["needs"]["probe"]["outputs"] == {}
    assert record["errors"]


@pytest.mark.parametrize("case", ["pytest-failure", "cancel"])
def test_dispatch_ref_guard(observer: ModuleType, case: str) -> None:
    """Only exact refs with no open PR can reach the production negative call."""
    branch = "negative" if case == "pytest-failure" else "cancel"
    environment = {
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "PROOF_CASE": case,
        "PROOF_REPOSITORY": "lgtm-hq/lgtm-ci",
        "PROOF_REF": f"refs/heads/proof/1297-{branch}",
        "PROOF_TOKEN": "local-test-token",
    }
    with (
        patch.dict(os.environ, environment),
        patch.object(observer.urllib.request.OpenerDirector, "open") as request,
    ):
        response = request.return_value.__enter__.return_value
        response.status = 200
        response.read.return_value = b"[]"
        observer.guard()
        actual_request = request.call_args.args[0]
        assert actual_request.full_url.startswith(
            "https://api.github.com/repos/lgtm-hq/lgtm-ci/pulls?"
        )
        response.read.return_value = b"[{}]"
        with pytest.raises(ValueError, match="no open PR"):
            observer.guard()
        response.status = 503
        with pytest.raises(ValueError, match="HTTP 503"):
            observer.guard()
        request.side_effect = OSError("API unavailable")
        with pytest.raises(OSError, match="API unavailable"):
            observer.guard()
        os.environ["PROOF_REF"] = "refs/heads/main"
        with pytest.raises(ValueError, match="exact owned"):
            observer.guard()


def test_workflow_and_fixture_contracts(observer: ModuleType) -> None:
    """Pin production, preserve four geometries and isolate negative discovery."""
    workflows = PROJECT_ROOT / ".github/workflows"
    positive = yaml.safe_load((workflows / "proof-python-skip.yml").read_text())
    negative_path = workflows / "proof-python-skip-negative.yml"
    negative = yaml.safe_load(negative_path.read_text())
    assert set(positive[True]) == {"pull_request", "push", "merge_group"}
    assert set(negative[True]) == {"workflow_dispatch"}
    calls = {key: positive["jobs"][key] for key in observer.COUNTS}
    for key, call in calls.items():
        assert call["uses"].endswith("@cade5e687630ce3208bf914d0b1590145f3d569e")
        assert call["with"]["job-name"] == f"Proof Python {key.title()}"
        assert call["with"]["artifact-prefix"] == f"proof_{key}"
        assert isinstance(call["with"]["pipeline-skip"], bool)
        assert call["with"]["test-path"] == "tests/pass"
    assert len({call["with"]["pipeline-skip"] for call in calls.values()}) == 1
    assert "python-versions" not in calls["single"]["with"]
    geometries = ("matrix", "empty", "commas")
    versions = [calls[key]["with"]["python-versions"] for key in geometries]
    assert versions == ["3.12,3.13", "", " , , "]
    for workflow in (positive, negative):
        observer_job = workflow["jobs"]["observe"]
        assert observer_job["if"] == "always()"
        record_step = next(
            step
            for step in observer_job["steps"]
            if step.get("name") == "Record and assert delivered outputs"
        )
        assert record_step["env"]["PROOF_NEEDS"] == "${{ toJSON(needs) }}"
        assert not any("continue-on-error" in job for job in workflow["jobs"].values())
    assert negative["jobs"]["probe"]["needs"] == "authorize"
    negative_inputs = negative["jobs"]["probe"]["with"]
    assert negative_inputs["working-directory"] == "tests/fixtures/python-skip-proof"
    assert negative_inputs["test-path"] == (
        "${{ inputs.case == 'pytest-failure' && 'controls/failure.py'"
        # The other case selects only the bounded sleeping control.
        " || 'controls/sleep.py' }}"
    )
    assert negative_inputs["python-version"] == "3.12"
    assert "python-versions" not in negative_inputs


def test_fixture_discovery_contracts() -> None:
    """Keep the fixture isolated and its negative controls explicitly selected."""
    project = tomllib.loads((FIXTURE / "pyproject.toml").read_text())
    lock = tomllib.loads((FIXTURE / "uv.lock").read_text())
    assert project["tool"]["uv"]["workspace"]["members"] == []
    assert {package["name"] for package in lock["package"]} >= {
        "python-skip-proof",
        "pytest",
        "pytest-json-report",
    }
    assert project["tool"]["pytest"]["ini_options"]["testpaths"] == ["tests/pass"]
    root_project = tomllib.loads((PROJECT_ROOT / "pyproject.toml").read_text())
    root_selection = root_project["tool"]["pytest"]["ini_options"]["testpaths"]
    assert root_selection == ["tests/python"]
    assert not list((FIXTURE / "controls").glob("test_*.py"))


def test_mixed_catalog_collection() -> None:
    """Exercise the actual nested conftest collision that broke required CI."""
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "--collect-only",
            "-q",
            "tests/python/catalog",
            "tests/python/test_python_skip_proof.py",
        ],
        cwd=PROJECT_ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "test_python_skip_proof.py::test_positive_routes" in result.stdout
    assert "catalog/test_consumer_scan.py::" in result.stdout
