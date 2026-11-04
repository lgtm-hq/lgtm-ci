#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Prove lower-ID replacements from GitHub concurrency cancellation evidence.

Priority is not chronological. Support only a unique successful same-PR peer
and a literal workflow concurrency prefix followed by the PR-number expression.
Unknown workflow syntax, job coverage or cancellation evidence stays closed.
"""

import base64
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any

from reconcile_check_retries import api, bind_jobs, jobs_for_run

CANCELLATION_PREFIX = "Canceling since a higher priority waiting request for "


def concurrency_group(source: str, number: int) -> str | None:
    """Recognize a deliberately restricted YAML root concurrency stanza.

    Reject duplicate/quoted/merged root keys and multiple documents rather than
    approximating YAML semantics. Nothing fetched from the repository executes.
    """
    nonempty = (line for line in source.splitlines() if line.strip())
    lines = [line for line in nonempty if not line.lstrip().startswith("#")]
    if lines[:1] == ["---"]:
        lines.pop(0)
    roots = [i for i, line in enumerate(lines) if not line.startswith(" ")]
    keys = []
    for index in roots:
        match = re.match(
            r"(name|'on'|on|run-name|permissions|env|defaults|concurrency|jobs):",
            lines[index],
        )
        if not match:
            return None
        key = match[1].strip("'")
        value = lines[index][match.end() :].strip()
        if key in ("name", "run-name"):
            if not value or re.search(r"[\"'\[\]{}&*!|>]", value):
                return None
        elif value:
            return None
        keys.append(key)
    if len(keys) != len(set(keys)) or "concurrency" not in keys:
        return None
    index = keys.index("concurrency")
    end = roots[index + 1] if index + 1 < len(roots) else len(lines)
    block = "\n".join(lines[roots[index] : end])
    match = re.fullmatch(
        r"concurrency:\n  group: (?:>-\n    )?([a-zA-Z0-9_./-]+)"
        r"\$\{\{ github\.event\.pull_request\.number(?: \|\| github\.ref)? \}\}"
        r"\n  cancel-in-progress: true",
        block,
    )
    return f"{match[1]}{number}" if match else None


def identity(run: dict[str, Any]) -> tuple[Any, ...] | None:
    """Require an exact repository, workflow and single current-head PR binding."""
    repo = os.environ["GITHUB_REPOSITORY"]
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    prs = run.get("pull_requests") or []
    if not run.get("workflow_id") or not re.fullmatch(
        r"\.github/workflows/[\w.-]+\.ya?ml", run.get("path", "")
    ):
        return None
    if (
        run.get("event") != "pull_request"
        or len(prs) != 1
        or run.get("head_sha") != os.environ["HEAD_SHA"]
        or run.get("repository", {}).get("full_name") != repo
    ):
        return None
    pr = prs[0]
    head_repo_id = run.get("head_repository", {}).get("id")
    if pr.get("head", {}).get("repo", {}).get("id") != head_repo_id:
        return None
    if (
        not isinstance(pr.get("number"), int)
        or pr["number"] < 1
        or pr.get("url") != f"{api_url}/repos/{repo}/pulls/{pr['number']}"
        or pr.get("head", {}).get("sha") != run["head_sha"]
        or pr.get("base", {}).get("repo", {}).get("id") != run["repository"].get("id")
    ):
        return None
    return (
        run["workflow_id"],
        run["path"],
        run["head_sha"],
        run["repository"],
        run.get("head_repository"),
        prs,
    )


def cancellation_proven(
    run: dict[str, Any],
    jobs: list[dict[str, Any]],
    work: Path,
) -> bool:
    """Bind each unstarted cancellation to GitHub's exact priority annotation."""
    repo = os.environ["GITHUB_REPOSITORY"]
    endpoint = f"repos/{repo}/contents/{run['path']}?ref={run['head_sha']}"
    record = json.loads(api(endpoint, work))
    if record.get("encoding") != "base64":
        return False
    encoded = record["content"].replace("\n", "")
    source = base64.b64decode(encoded, validate=True).decode()
    group = concurrency_group(source, run["pull_requests"][0]["number"])
    if not group:
        return False
    cancelled = [j for j in jobs if j["conclusion"] == "cancelled"]
    for job in cancelled:
        if job.get("runner_id") or job.get("steps") != []:
            return False
        raw = api(
            f"repos/{repo}/check-runs/{job['check_id']}/annotations?per_page=100",
            work,
            paginate=True,
        )
        # This contract accepts exactly one annotation and therefore one page.
        annotations = json.loads(raw)
        if len(annotations) != 1:
            return False
        expected = {
            "path": ".github",
            "start_line": 1,
            "end_line": 1,
            "annotation_level": "failure",
            "title": "",
            "raw_details": "",
            "message": f"{CANCELLATION_PREFIX}{group} exists",
        }
        if any(annotations[0].get(k) != value for k, value in expected.items()):
            return False
    return bool(cancelled)


def coverage_proven(
    old_jobs: list[dict[str, Any]],
    new_jobs: list[dict[str, Any]],
    checks: list[dict[str, Any]],
) -> bool:
    """Retain failures and require successful multiplicity for non-skipped jobs."""
    cancelled = [j for j in old_jobs if j["conclusion"] == "cancelled"]
    ids = {j["check_id"] for j in cancelled}
    if any(c.get("annotations_count") != 1 for c in checks if c["id"] in ids):
        return False
    safe = {"success", "skipped", "neutral", "cancelled"}
    if any(j["conclusion"] not in safe for j in old_jobs):
        return False
    needed = Counter(j["name"] for j in old_jobs if j["conclusion"] != "skipped")
    done = Counter(
        j["name"]
        for j in new_jobs
        if j["conclusion"] == "success" and j.get("runner_id") and j.get("steps")
    )
    return bool(done) and not needed - done


def replacement_window(
    new: dict[str, Any],
    old_jobs: list[dict[str, Any]],
    new_jobs: list[dict[str, Any]],
) -> bool:
    """Require a queued peer whose successful execution follows cancellation."""

    def timestamp(value: str) -> datetime:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")

    cancelled = [j for j in old_jobs if j["conclusion"] == "cancelled"]
    if not cancelled:
        return False
    boundary = max(timestamp(j["completed_at"]) for j in cancelled)
    successful = (j for j in new_jobs if j["conclusion"] == "success")
    starts = [timestamp(j["started_at"]) for j in successful]
    return bool(starts) and timestamp(new["created_at"]) <= boundary < min(starts)


def reconcile(work: Path) -> None:
    """Attach a proof edge only after complete API jobs/checks and coverage agree."""
    runs = json.loads((work / "supersession-runs.json").read_text())
    checks = json.loads((work / "checks.json").read_text())
    all_runs = json.loads((work / "runs.json").read_text())
    for old in runs:
        if old["conclusion"] != "cancelled" or identity(old) is None:
            continue
        old_identity = identity(old)
        others = (r for r in runs if r["id"] != old["id"])
        peers = [r for r in others if identity(r) == old_identity]
        if len(peers) != 1:
            continue
        new = peers[0]
        if (
            new["id"] >= old["id"]
            or new["conclusion"] != "success"
            or old["run_attempt"] != 1
            or new["run_attempt"] != 1
        ):
            continue
        old_jobs = jobs_for_run(old, work)
        new_jobs = jobs_for_run(new, work)
        bind_jobs(old, old_jobs, checks)
        bind_jobs(new, new_jobs, checks)
        if not coverage_proven(old_jobs, new_jobs, checks):
            continue
        if not replacement_window(new, old_jobs, new_jobs):
            continue
        if not cancellation_proven(old, old_jobs, work):
            continue
        for run in all_runs:
            if run["id"] == old["id"]:
                run["evidence_replacement"] = new["id"]
    (work / "runs.json").write_text(json.dumps(all_runs))


if __name__ == "__main__":
    try:
        reconcile(Path(sys.argv[1]))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        print("Cannot verify concurrency cancellation evidence", file=sys.stderr)
        sys.exit(1)
