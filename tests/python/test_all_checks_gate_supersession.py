"""Replay ai-skills #641 through the production gate, preserving all API surfaces."""

import base64
import json
import subprocess
from pathlib import Path
from typing import Any

import pytest
from test_all_checks_gate_retry import gate

REPO = "lgtm-hq/ai-skills"
SHA = "bc7138fce6e801cbfec4210158bacfd65e01b2d4"
OLD = 41787587794
NEW = 41787587770
PREFIX = f"repos/{REPO}/"
RUNS = f"{PREFIX}actions/runs?head_sha={SHA}&per_page=100"
CHECKS = f"{PREFIX}commits/{SHA}/check-runs?filter=all&per_page=100"
ANNOTATIONS = f"{PREFIX}check-runs/126433181355/annotations?per_page=100"
OLD_JOBS = f"{PREFIX}actions/runs/{OLD}/jobs?filter=all&per_page=100"
NEW_JOBS = f"{PREFIX}actions/runs/{NEW}/jobs?filter=all&per_page=100"


def corrupt_repository_ids(
    runs: list[dict[str, Any]], source: str, malformed: str, peer: str
) -> None:
    """Change captured metadata in memory while retaining all other evidence."""
    for run in runs:
        if run["id"] not in {OLD, NEW} or (
            peer != "both" and run["id"] != {"old": OLD, "new": NEW}[peer]
        ):
            continue
        repositories = {
            "run": run["repository"],
            "head": run["head_repository"],
            "pr-head": run["pull_requests"][0]["head"]["repo"],
            "pr-base": run["pull_requests"][0]["base"]["repo"],
        }
        for name, repository in repositories.items():
            selected = {
                "base-pair": ("run", "pr-base"),
                "head-pair": ("head", "pr-head"),
                "all": tuple(repositories),
            }.get(source, (source,))
            if name not in selected:
                continue
            if malformed == "missing":
                repository.pop("id")
            else:
                repository["id"] = {
                    "null": None,
                    "true": True,
                    "false": False,
                    "zero": 0,
                    "negative": -1,
                    "string": "123",
                }[malformed]


def add_old_job(urls: dict[str, Any], scenario: str) -> None:
    """Keep the cancelled job while adding failed, duplicate or omitted work."""
    extra_id = 126433181356
    extra = urls[OLD_JOBS]["jobs"][0] | {
        "id": extra_id,
        "check_run_url": f"https://api.github.com/{PREFIX}check-runs/{extra_id}",
    }
    if scenario == "failed-work-in-cancelled-run":
        extra.update(
            name="Independent failed work",
            conclusion="failure",
            runner_id=1,
            steps=[{"name": "Failed step", "conclusion": "failure"}],
        )
    if scenario != "omitted-job":
        urls[OLD_JOBS]["total_count"] += 1
        urls[OLD_JOBS]["jobs"].append(extra)
    checks = urls[CHECKS]["check_runs"]
    old_check = next(c for c in checks if c["id"] == 126433181355)
    checks.append(
        old_check
        | {
            "id": extra_id,
            "name": extra["name"],
            "conclusion": extra["conclusion"],
            "html_url": f"https://github.com/{REPO}/actions/runs/{OLD}/job/{extra_id}",
        }
    )


# Each branch independently changes one evidence surface in the replay.
# pylint: disable=too-many-branches,too-many-statements
def replay(
    tmp_path: Path,
    changes: str = "valid",
    repository_ids: tuple[str, str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Use the existing strict gh fake with captured complete head collections."""
    fixture = Path(__file__).parent / "fixtures/gate_supersession/incident.json"
    urls = json.loads(fixture.read_text())
    runs = urls[RUNS]["workflow_runs"]
    old = next(r for r in runs if r["id"] == OLD)
    new = next(r for r in runs if r["id"] == NEW)
    assert old["created_at"] == new["created_at"]
    if repository_ids:
        corrupt_repository_ids(runs, *repository_ids)
    if changes == "missing":
        urls[ANNOTATIONS] = [[]]
    elif changes == "ambiguous":
        urls[ANNOTATIONS][0] *= 2
    elif changes == "empty-response":
        urls[ANNOTATIONS] = []
    elif changes == "multiple-documents":
        urls[ANNOTATIONS] *= 2
    elif changes == "manual":
        urls[ANNOTATIONS][0][0]["message"] = "The operation was canceled."
    elif changes == "wrong-group":
        urls[ANNOTATIONS][0][0]["message"] += "-other"
    elif changes == "wrong-sha":
        new["head_sha"] = "f" * 40
    elif changes == "wrong-pr":
        new["pull_requests"][0]["number"] = 642
    elif changes == "wrong-repo":
        new["repository"]["full_name"] = "other/repo"
    elif changes == "wrong-workflow":
        new["workflow_id"] += 1
    elif changes == "wrong-path":
        new["path"] = ".github/workflows/other.yml"
    elif changes == "skipped":
        new["conclusion"] = "skipped"
        for c in urls[CHECKS]["check_runs"]:
            if f"/runs/{NEW}/" in c["html_url"]:
                c["conclusion"] = "skipped"
    elif changes == "ambiguous-peer":
        runs.append(new | {"id": NEW - 1})
    elif changes == "truncated-jobs":
        endpoint = f"{PREFIX}actions/runs/{NEW}/jobs?filter=all&per_page=100"
        urls[endpoint]["total_count"] += 1
    elif changes == "annotations-error":
        urls[ANNOTATIONS] = {"error": "HTTP 500"}
    elif changes == "source-error":
        endpoint = next(k for k in urls if "/contents/" in k)
        urls[endpoint] = {"error": "HTTP 500"}
    elif changes == "wrong-source-group":
        endpoint = next(k for k in urls if "/contents/" in k)
        content = base64.b64decode(urls[endpoint]["content"])
        urls[endpoint]["content"] = base64.b64encode(
            content.replace(b"install-plane-release-gate-", b"other-gate-")
        ).decode()
    elif changes == "created-after-cancellation":
        new["created_at"] = "2026-11-04T06:44:56Z"
    elif changes == "started-before-cancellation":
        urls[NEW_JOBS]["jobs"][0]["started_at"] = "2026-11-04T06:44:54Z"
    elif changes == "started-at-cancellation":
        urls[NEW_JOBS]["jobs"][0]["started_at"] = "2026-11-04T06:44:55Z"
    elif changes == "missing-created-at":
        new.pop("created_at")
    elif changes == "missing-completed-at":
        urls[OLD_JOBS]["jobs"][0].pop("completed_at")
    elif changes == "missing-started-at":
        urls[NEW_JOBS]["jobs"][0].pop("started_at")
    elif changes in (
        "failed-work-in-cancelled-run",
        "missing-job-coverage",
        "omitted-job",
    ):
        add_old_job(urls, changes)
    elif changes == "real-failure":
        for c in urls[CHECKS]["check_runs"]:
            if f"/runs/{OLD}/" in c["html_url"]:
                c["conclusion"] = "failure"
        urls[f"{PREFIX}actions/runs/{OLD}/jobs?filter=all&per_page=100"]["jobs"][0][
            "conclusion"
        ] = "failure"
    elif changes == "status-failure":
        urls[f"{PREFIX}commits/{SHA}/status?per_page=100"]["statuses"] = [
            {"context": "required-external", "state": "failure"}
        ]
    elif changes == "higher-id":
        new["id"] = OLD + 1
        for c in urls[CHECKS]["check_runs"]:
            c["html_url"] = c["html_url"].replace(f"/runs/{NEW}/", f"/runs/{OLD + 1}/")
    result: subprocess.CompletedProcess[str] = gate(
        tmp_path,
        {
            "jobs": [],
            "run": old,
            "logs": {},
            "overrides": urls,
            "env": {
                "HEAD_SHA": SHA,
                "GITHUB_REPOSITORY": REPO,
                "SELF_RUN_ID": "41787588462",
                "SELF_WORKFLOW_REF": (
                    f"{REPO}/.github/workflows/" "all-checks-gate.yml@refs/heads/main"
                ),
            },
        },
    )

    return result


@pytest.mark.parametrize("scenario", ["valid", "higher-id"])
def test_captured_concurrency_replacement(tmp_path: Path, scenario: str) -> None:
    """GitHub's priority cancellation can select a lower numeric run ID."""
    result = replay(tmp_path, scenario)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "status=passed" in (tmp_path / "output").read_text()


@pytest.mark.parametrize(
    "source", ["run", "head", "pr-head", "pr-base", "base-pair", "head-pair", "all"]
)
@pytest.mark.parametrize(
    "malformed", ["missing", "null", "true", "false", "zero", "negative", "string"]
)
def test_repository_ids(tmp_path: Path, source: str, malformed: str) -> None:
    """Each source requires a positive, non-boolean integer repository ID."""
    result = replay(tmp_path, repository_ids=(source, malformed, "both"))
    assert result.returncode != 0, result.stdout + result.stderr
    assert "status=failed" in (tmp_path / "output").read_text()
    assert "workflow run Install plane release gate: cancelled" in result.stdout
    assert "API poll failed" not in result.stdout


@pytest.mark.parametrize("peer", ["old", "new"])
@pytest.mark.parametrize(
    "malformed", ["missing", "null", "true", "false", "zero", "negative", "string"]
)
def test_peer_repository_ids(tmp_path: Path, peer: str, malformed: str) -> None:
    """Neither peer can establish proof with invalid repository IDs."""
    result = replay(tmp_path, repository_ids=("all", malformed, peer))
    assert result.returncode != 0, result.stdout + result.stderr
    assert "status=failed" in (tmp_path / "output").read_text()
    assert "workflow run Install plane release gate: cancelled" in result.stdout
    assert "API poll failed" not in result.stdout


@pytest.mark.parametrize(
    "scenario",
    [
        "missing",
        "ambiguous",
        "empty-response",
        "multiple-documents",
        "manual",
        "wrong-group",
        "wrong-sha",
        "wrong-pr",
        "wrong-repo",
        "wrong-workflow",
        "wrong-path",
        "skipped",
        "real-failure",
        "status-failure",
        "ambiguous-peer",
        "truncated-jobs",
        "annotations-error",
        "source-error",
        "wrong-source-group",
        "created-after-cancellation",
        "started-before-cancellation",
        "started-at-cancellation",
        "missing-created-at",
        "missing-completed-at",
        "missing-started-at",
        "failed-work-in-cancelled-run",
        "missing-job-coverage",
        "omitted-job",
    ],
)
def test_unproven_concurrency_stays_closed(tmp_path: Path, scenario: str) -> None:
    """Missing evidence, identity mismatches and real failed work remain gated."""
    result = replay(tmp_path, scenario)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "status=failed" in (tmp_path / "output").read_text()
    if scenario in ("missing", "ambiguous"):
        assert "workflow run Install plane release gate: cancelled" in result.stdout
        assert "API poll failed" not in result.stdout
        assert "Cannot verify concurrency cancellation evidence" not in result.stderr
    if scenario in (
        "empty-response",
        "multiple-documents",
        "annotations-error",
        "source-error",
    ):
        assert "API poll failed" in result.stdout
        assert "Cannot verify concurrency cancellation evidence" in result.stderr
    if scenario == "failed-work-in-cancelled-run":
        assert "check Independent failed work: failure" in result.stdout
        assert "workflow run Install plane release gate: cancelled" in result.stdout
