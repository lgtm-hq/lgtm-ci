# SPDX-License-Identifier: MIT
"""Local source/observer contracts; these do not prove hosted job names."""

import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest
import yaml
from conftest import PROJECT_ROOT, load_script_module

OBSERVER = load_script_module("scripts/ci/actions/python-skip-proof-observe.py")
FIXTURE = PROJECT_ROOT / "tests/fixtures/python-skip-proof"


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
def test_positive_routes(event: str) -> None:
    """Baseline and PR skips work; non-PR zero counts are rejected."""
    metadata = {"case": "positive", "event": event, "draft": "false"}
    needs = {key: delivered(str(count)) for key, count in OBSERVER.COUNTS.items()}
    assert OBSERVER.errors_for(needs, metadata) == []
    needs = {key: delivered() for key in OBSERVER.COUNTS}
    assert bool(OBSERVER.errors_for(needs, metadata)) == (event != "pull_request")


@pytest.mark.parametrize("result", ["failure", "cancelled", "skipped"])
@pytest.mark.parametrize("passed", [None, "", "false", "true"])
def test_negative_outputs(result: str, passed: str | None) -> None:
    """Absence stays absent; neither wrong conclusions nor true outputs pass."""
    outputs = {} if passed is None else {"passed": passed}
    needs = {"probe": {"result": result, "outputs": outputs}}
    for case, expected in (("pytest-failure", "failure"), ("cancel", "cancelled")):
        errors = OBSERVER.errors_for(needs, {"case": case})
        assert bool(errors) == (result != expected or passed == "true")
    assert needs["probe"]["outputs"] == outputs


def test_draft_and_string_contract() -> None:
    """Draft skips cannot claim true; boolean outputs are invalid."""
    metadata = {"case": "positive", "event": "pull_request", "draft": "true"}
    needs: dict[str, Any] = {}
    for key in OBSERVER.COUNTS:
        needs[key] = {"result": "skipped", "outputs": {}}
    assert not OBSERVER.errors_for(needs, metadata)
    needs["single"]["outputs"]["passed"] = True
    assert OBSERVER.errors_for(needs, metadata)


def test_failed_observation_retains_raw(tmp_path: Path) -> None:
    """A failed assertion still writes exact raw input and actual output types."""
    raw = '{ "probe": {"result": "cancelled", "outputs": {}} }'
    result = subprocess.run(
        [sys.executable, str(Path(OBSERVER.__file__))],
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
def test_dispatch_ref_guard(case: str) -> None:
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
        patch.object(OBSERVER.urllib.request, "urlopen") as request,
    ):
        request.return_value.__enter__.return_value.read.return_value = b"[]"
        OBSERVER.guard()
        request.return_value.__enter__.return_value.read.return_value = b"[{}]"
        with pytest.raises(ValueError, match="no open PR"):
            OBSERVER.guard()
        request.side_effect = OSError("API unavailable")
        with pytest.raises(OSError, match="API unavailable"):
            OBSERVER.guard()
        os.environ["PROOF_REF"] = "refs/heads/main"
        with pytest.raises(ValueError, match="exact owned"):
            OBSERVER.guard()


def test_workflow_and_fixture_contracts() -> None:
    """Pin production, preserve four geometries and isolate negative discovery."""
    workflows = PROJECT_ROOT / ".github/workflows"
    positive = yaml.safe_load((workflows / "proof-python-skip.yml").read_text())
    negative_path = workflows / "proof-python-skip-negative.yml"
    negative = yaml.safe_load(negative_path.read_text())
    assert set(positive[True]) == {"pull_request", "push", "merge_group"}
    assert set(negative[True]) == {"workflow_dispatch"}
    calls = {key: positive["jobs"][key] for key in OBSERVER.COUNTS}
    for key, call in calls.items():
        assert call["uses"].endswith("@761e2f173be08f57f0be18d8332e2b063387d987")
        assert call["with"]["job-name"] == f"Proof Python {key.title()}"
        assert call["with"]["artifact-prefix"] == f"proof_{key}"
        assert isinstance(call["with"]["pipeline-skip"], bool)
        assert call["with"]["test-path"] == "tests/pass"
    assert "python-versions" not in calls["single"]["with"]
    geometries = ("matrix", "empty", "commas")
    versions = [calls[key]["with"]["python-versions"] for key in geometries]
    assert versions == ["3.12,3.13", "", " , , "]
    for workflow in (positive, negative):
        observer = workflow["jobs"]["observe"]
        assert observer["if"] == "always()"
        assert observer["steps"][2]["env"]["PROOF_NEEDS"] == "${{ toJSON(needs) }}"
        assert not any("continue-on-error" in job for job in workflow["jobs"].values())
    assert negative["jobs"]["probe"]["needs"] == "authorize"
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
