"""Synthetic API regressions for same-run retry and dynamic job obligations.

Names and graph model spotify-curator run 39800719692; IDs and receipts are
deliberately synthetic, not captured CI output.
"""

import base64
import json
import os
import subprocess
from pathlib import Path
from typing import Any

import pytest
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
REPO = "lgtm-hq/example"
REPO_URL = f"https://github.com/{REPO}"
CHECK_URL = f"https://api.github.com/repos/{REPO}/check-runs"
SHA = "0123456789abcdef0123456789abcdef01234567"
WORKFLOW_SHA = "9ea778eb4e6b876d60b7b3d7d0d0aee5182717bb"
WORKFLOW = "lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml"
PREFIX = "codeql / "
ANALYSIS = PREFIX + "🔬 CodeQL Analysis"
SETUP = PREFIX + "Setup CodeQL matrix"
PLACEHOLDER = PREFIX + "inputs.job-name"


def job(job_id: int, name: str, attempt: int, conclusion: str) -> dict[str, Any]:
    """Build a synthetic, API-shaped job with exact check binding."""
    executed = name != PLACEHOLDER and conclusion != "skipped"
    return {
        "id": job_id,
        "run_id": 1,
        "run_attempt": attempt,
        "head_sha": SHA,
        "name": name,
        "status": "completed",
        "conclusion": conclusion,
        "check_run_url": f"https://api.github.com/repos/{REPO}/check-runs/{job_id}",
        "runner_id": job_id if executed else None,
        "steps": [{"name": "Set up job", "conclusion": "success"}] if executed else [],
    }


def receipt(name: str, languages: str = "actions") -> str:
    """Model the runner-generated pre-step reusable-workflow header."""
    lines = [
        "Current runner version: '2.338.0'",
        f"Uses: {WORKFLOW}@{WORKFLOW_SHA}",
        "##[group] Inputs",
        f"  languages: {languages}",
        "  build-mode: none",
        "  language-build-modes: ",
        f"  tooling-ref: {WORKFLOW_SHA}",
        "  job-name: 🔬 CodeQL Analysis",
        "##[endgroup]",
        f"Complete job name: {name}",
        "##[group]Run an action",
    ]
    return "\n".join(f"2026-10-22T15:25:05.0000000Z {line}" for line in lines)


@pytest.fixture(name="responses")
def retry_responses() -> dict[str, Any]:
    """Provide a complete same-run cancellation/retry, with immutable source."""
    jobs = [
        job(11, SETUP, 1, "cancelled"),
        job(12, PLACEHOLDER, 1, "cancelled"),
        job(21, SETUP, 2, "success"),
        job(22, ANALYSIS, 2, "success"),
    ]
    run = {
        "id": 1,
        "name": "CodeQL",
        "path": ".github/workflows/codeql.yml",
        "run_attempt": 2,
        "head_sha": SHA,
        "check_suite_id": 50,
        "status": "completed",
        "conclusion": "success",
        "referenced_workflows": [
            {"path": f"{WORKFLOW}@{WORKFLOW_SHA}", "sha": WORKFLOW_SHA},
        ],
    }
    return {
        "run": run,
        "jobs": jobs,
        "logs": {str(j["id"]): receipt(j["name"]) for j in jobs},
        "overrides": {},
    }


def gate(tmp_path: Path, responses: dict[str, Any]) -> subprocess.CompletedProcess[str]:
    """Run the real Bash/jq gate with strict, raw, paginated gh responses."""
    jobs = responses["jobs"]
    checks = [
        {
            "id": j.get("check_id", j["id"]),
            "name": j["name"],
            "status": j["status"],
            "conclusion": j["conclusion"],
            "head_sha": SHA,
            "app": {"slug": "github-actions"},
            "check_suite": {"id": j.get("suite", 50)},
            "html_url": f"{REPO_URL}/actions/runs/{j['run_id']}/job/{j['id']}",
        }
        for j in responses.get("checks", jobs)
    ]
    urls: dict[str, Any] = {
        f"repos/{REPO}/actions/runs?head_sha={SHA}&per_page=100": {
            "workflow_runs": responses.get("runs", [responses["run"]]),
        },
        f"repos/{REPO}/commits/{SHA}/check-runs?filter=all&per_page=100": {
            "check_runs": checks,
        },
        f"repos/{REPO}/commits/{SHA}/status?per_page=100": {"statuses": []},
        f"repos/{REPO}/actions/runs/1/jobs?filter=all&per_page=100": {
            "total_count": len(jobs),
            "jobs": jobs,
        },
    }
    for job_id, log in responses["logs"].items():
        urls[f"repos/{REPO}/actions/jobs/{job_id}/logs"] = log
    for source in (
        ".github/workflows/reusable-codeql.yml",
        "scripts/ci/actions/generate-codeql-matrix.sh",
    ):
        urls[f"repos/lgtm-hq/lgtm-ci/contents/{source}?ref={WORKFLOW_SHA}"] = {
            "encoding": "base64",
            "content": base64.b64encode((ROOT / source).read_bytes()).decode(),
        }
    urls.update(responses["overrides"])
    fixture_path = tmp_path / "responses.json"
    fixture_path.write_text(json.dumps(urls))
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    mock = bin_dir / "gh"
    mock.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, subprocess, sys\n"
        "args = sys.argv[1:]\n"
        "if args == ['api', '--help']:\n"
        " print('--allow-escape-sequences'); sys.exit(0)\n"
        "url = next((a for a in args if a.startswith('repos/')), '')\n"
        "with open(os.environ['GH_CALLS'], 'a') as f: f.write(url + '\\n')\n"
        "with open(os.environ['GATE_RESPONSES']) as f: responses = json.load(f)\n"
        "if url not in responses: sys.exit('unexpected API: ' + url)\n"
        "value = responses[url]\n"
        "if isinstance(value, dict) and 'error' in value: sys.exit(value['error'])\n"
        "pages = value if isinstance(value, list) else [value]\n"
        "for page in pages:\n"
        " if isinstance(page, str): print(page); continue\n"
        " query = args[args.index('--jq') + 1] if '--jq' in args else '.'\n"
        " r = subprocess.run(['jq', '-c', query], input=json.dumps(page), "
        "text=True, check=True)\n"
    )
    mock.chmod(0o755)
    (bin_dir / "sleep").write_text("#!/bin/sh\nexit 0\n")
    (bin_dir / "sleep").chmod(0o755)
    env = os.environ | {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HEAD_SHA": SHA,
        "GITHUB_REPOSITORY": REPO,
        "SELF_RUN_ID": "900",
        "SELF_WORKFLOW_REF": f"{REPO}/.github/workflows/gate.yml@refs/heads/main",
        "GATE_RESPONSES": str(fixture_path),
        "GH_CALLS": str(tmp_path / "gh-calls"),
        "POLL_INTERVAL": "1",
        "SETTLE_SECONDS": "0",
        "TIMEOUT_SECONDS": "20",
        "MAX_API_ERRORS": "1",
        "GITHUB_OUTPUT": str(tmp_path / "output"),
        "GITHUB_STEP_SUMMARY": str(tmp_path / "summary"),
    }
    for key in ("IGNORE_PATTERN", "ALLOW_EMPTY", "FAIL_ON_DRAFT", "PR_DRAFT"):
        env.pop(key, None)
    env.update(responses.get("env", {}))
    return subprocess.run(
        ["bash", str(ROOT / "scripts/ci/actions/all-checks-gate.sh")],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )


def test_retry_recovers_placeholder(tmp_path: Path, responses: dict[str, Any]) -> None:
    """A runnerless attempt-1 placeholder yields to the actual attempt-2 analysis."""
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).described_as(result.stdout + result.stderr).is_zero()
    assert_that(result.stdout).contains("All 2 other check(s) passed")
    assert_that((tmp_path / "output").read_text()).contains("status=passed")
    assert_that((tmp_path / "summary").read_text()).does_not_contain(PLACEHOLDER)


@pytest.mark.parametrize("conclusion", ["cancelled", "failure", "skipped", "neutral"])
def test_unsuccessful_replacement_retains_cancellation(
    tmp_path: Path,
    responses: dict[str, Any],
    conclusion: str,
) -> None:
    """Only actual success can recover unresolved cancelled work."""
    responses["jobs"][-1]["conclusion"] = conclusion
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that(result.stdout).contains(f"check {PLACEHOLDER}: cancelled")


def test_setup_is_insufficient(tmp_path: Path, responses: dict[str, Any]) -> None:
    """A complete but insufficient job list cannot stand in for required analysis."""
    responses["jobs"].pop()
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that(result.stdout).contains(f"check {PLACEHOLDER}: cancelled")


@pytest.mark.parametrize(
    "case",
    [
        "unrelated-sibling",
        "different-run",
        "latest-placeholder",
        "executed-cancellation",
        "real-cancellation",
        "multi-language",
        "auto-detect",
        "different-inputs",
        "missing-old-receipt",
        "missing-current-receipt",
        "spoofed-step-receipt",
        "multiline-input",
        "different-source",
        "different-tooling",
        "missing-reference",
        "retained-failure",
        "partial-matrix",
    ],
)
def test_unproven_replacements_fail_closed(
    tmp_path: Path,
    responses: dict[str, Any],
    case: str,
) -> None:
    """Require source identity, both receipts and complete single-leg execution."""
    if case == "unrelated-sibling":
        responses["jobs"][-1]["name"] = PREFIX + "Security report"
    elif case == "different-run":
        responses["jobs"][-1]["run_id"] = 2
    elif case == "latest-placeholder":
        responses["jobs"][1]["run_attempt"] = 2
    elif case == "executed-cancellation":
        responses["jobs"][1]["runner_id"] = 123
    elif case == "real-cancellation":
        responses["jobs"][1]["name"] = PREFIX + "Other required work"
    elif case in ("multi-language", "auto-detect", "partial-matrix"):
        languages = "" if case == "auto-detect" else "python,javascript"
        responses["logs"] = {
            key: receipt(j["name"], languages=languages)
            for key, j in zip(responses["logs"], responses["jobs"], strict=True)
        }
        if case == "partial-matrix":
            responses["jobs"].append(job(23, ANALYSIS, 2, "cancelled"))
    elif case == "retained-failure":
        responses["jobs"].append(job(31, "Another required job", 2, "failure"))
    else:
        invalidate_receipt(responses=responses, case=case)
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that((tmp_path / "output").read_text()).contains("status=failed")


def invalidate_receipt(responses: dict[str, Any], case: str) -> None:
    """Alter the runner/source proof independently from observed job membership."""
    if case == "different-inputs":
        responses["logs"]["11"] = receipt(SETUP, languages="python")
    elif case in ("missing-old-receipt", "missing-current-receipt"):
        key = "11" if case == "missing-old-receipt" else "22"
        responses["logs"][key] = ""
    elif case == "spoofed-step-receipt":
        step = "2026-10-22T15:25:05.0000000Z ##[group]Run echo\n"
        responses["logs"]["11"] = step + receipt(SETUP)
    elif case == "multiline-input":
        responses["logs"]["11"] = receipt(SETUP, languages="actions\n,javascript")
    elif case == "different-source":
        endpoint = (
            "repos/lgtm-hq/lgtm-ci/contents/.github/workflows/"
            f"reusable-codeql.yml?ref={WORKFLOW_SHA}"
        )
        responses["overrides"][endpoint] = {"encoding": "base64", "content": "e30="}
    elif case == "different-tooling":
        responses["logs"]["11"] = receipt(SETUP).replace(
            f"tooling-ref: {WORKFLOW_SHA}",
            "tooling-ref: main",
        )
    elif case == "missing-reference":
        responses["run"]["referenced_workflows"] = []
    else:
        raise ValueError(f"Unknown receipt scenario: {case}")


@pytest.mark.parametrize(
    "case",
    [
        "truncated",
        "duplicate",
        "inconsistent-total",
        "api-failure",
        "log-api-failure",
        "source-api-failure",
        "wrong-head",
        "missing-check",
        "wrong-check-binding",
    ],
)
def test_incomplete_api_evidence_fails_the_poll(
    tmp_path: Path,
    responses: dict[str, Any],
    case: str,
) -> None:
    """Transport, pagination and check binding errors cannot produce a verdict."""
    endpoint = f"repos/{REPO}/actions/runs/1/jobs?filter=all&per_page=100"
    jobs = responses["jobs"]
    if case == "truncated":
        responses["overrides"][endpoint] = {"total_count": 4, "jobs": jobs[:3]}
    elif case == "duplicate":
        responses["overrides"][endpoint] = {
            "total_count": 4,
            "jobs": jobs[:3] + jobs[:1],
        }
    elif case == "inconsistent-total":
        responses["overrides"][endpoint] = [
            {"total_count": 4, "jobs": jobs[:2]},
            {"total_count": 3, "jobs": jobs[2:]},
        ]
    elif case == "api-failure":
        responses["overrides"][endpoint] = {"error": "HTTP 500"}
    elif case == "log-api-failure":
        log_url = f"repos/{REPO}/actions/jobs/11/logs"
        responses["overrides"][log_url] = {"error": "HTTP 500"}
    elif case == "source-api-failure":
        responses["overrides"][
            "repos/lgtm-hq/lgtm-ci/contents/.github/workflows/"
            f"reusable-codeql.yml?ref={WORKFLOW_SHA}"
        ] = {"error": "HTTP 500"}
    elif case == "wrong-head":
        jobs[-1]["head_sha"] = "f" * 40
    elif case == "missing-check":
        responses["checks"] = jobs[:3]
    elif case == "wrong-check-binding":
        jobs[-1]["check_run_url"] = f"https://api.github.com/repos/{REPO}/check-runs/21"
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that(result.stdout).contains("consecutive API polls failed")


def test_paginated_retry_passes(tmp_path: Path, responses: dict[str, Any]) -> None:
    """Reconciliation consumes every page rather than silently accepting a prefix."""
    jobs = responses["jobs"]
    jobs_url = f"repos/{REPO}/actions/runs/1/jobs?filter=all&per_page=100"
    responses["overrides"][jobs_url] = [
        {"total_count": 4, "jobs": jobs[:2]},
        {"total_count": 4, "jobs": jobs[2:]},
    ]
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).described_as(result.stdout + result.stderr).is_zero()
    assert_that((tmp_path / "gh-calls").read_text()).contains(jobs_url)


def test_shared_name_current_matrix_failure_survives(
    tmp_path: Path,
    responses: dict[str, Any],
) -> None:
    """A newer successful matrix ID cannot hide a failed leg in the same attempt."""
    responses["jobs"] = [
        job(21, "Matrix", 2, "failure"),
        job(22, "Matrix", 2, "success"),
    ]
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that(result.stdout).contains("check Matrix: failure")
    assert_that(result.stdout).contains("check Matrix: success")


def test_retry_rate_limit_uses_outer_backoff(
    tmp_path: Path,
    responses: dict[str, Any],
) -> None:
    """New evidence requests share the gate's existing rate-limit policy."""
    endpoint = f"repos/{REPO}/actions/runs/1/jobs?filter=all&per_page=100"
    responses["overrides"][endpoint] = {"error": "secondary rate limit (HTTP 429)"}
    responses["env"] = {"TIMEOUT_SECONDS": "0"}
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that(result.stdout).contains("API rate limit hit; waiting 60s")
    assert_that(result.stdout).does_not_contain("API poll failed")


def test_matrix_success_keeps_all_ids(
    tmp_path: Path,
    responses: dict[str, Any],
) -> None:
    """Every observed successful matrix leg counts, even with shared names."""
    responses["jobs"] = [
        job(21, "Matrix", 2, "success"),
        job(22, "Matrix", 2, "success"),
    ]
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_zero()
    assert_that(result.stdout).contains("All 2 other check(s) passed")


def test_success_in_another_run_is_insufficient(
    tmp_path: Path,
    responses: dict[str, Any],
) -> None:
    """Successful work in a different run cannot retire a renamed cancellation."""
    other = job(32, ANALYSIS, 1, "success")
    other.update(run_id=2, suite=60)
    responses["checks"] = responses["jobs"][:-1] + [other]
    responses["jobs"].pop()
    responses["runs"] = [
        responses["run"],
        responses["run"] | {"id": 2, "run_attempt": 1, "check_suite_id": 60},
    ]
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that(result.stdout).contains(f"check {PLACEHOLDER}: cancelled")


def test_distinct_job_and_check_ids(
    tmp_path: Path,
    responses: dict[str, Any],
) -> None:
    """Bind via check_run_url, without equating Actions job and check-run IDs."""
    for item in responses["jobs"]:
        item["check_id"] = item["id"] + 1000
        item["check_run_url"] = f"{CHECK_URL}/{item['check_id']}"
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).described_as(result.stdout + result.stderr).is_zero()
    assert_that(result.stdout).contains("All 2 other check(s) passed")


def test_carried_success_is_kept(
    tmp_path: Path,
    responses: dict[str, Any],
) -> None:
    """A successful job not retried remains part of the gate's obligations."""
    responses["jobs"] = [
        job(11, "Carried", 1, "success"),
        job(22, "Retry", 2, "success"),
    ]
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_zero()
    assert_that(result.stdout).contains("All 2 other check(s) passed")


def test_ambiguous_historical_matrix_stays_closed(
    tmp_path: Path,
    responses: dict[str, Any],
) -> None:
    """A single later shared-name success does not prove both old legs recovered."""
    responses["jobs"] = [
        job(11, "Matrix", 1, "failure"),
        job(12, "Matrix", 1, "success"),
        job(22, "Matrix", 2, "success"),
    ]
    result = gate(tmp_path=tmp_path, responses=responses)
    assert_that(result.returncode).is_not_zero()
    assert_that(result.stdout).contains("check Matrix: failure")
