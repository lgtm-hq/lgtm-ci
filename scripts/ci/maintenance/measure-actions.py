#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only, resumable Actions measurement; see docs/actions/measurement.md.

Only GET requests are made. API responses/checkpoints can contain private metadata;
keep the output directory outside the repository. No logs or secrets are fetched.
"""

# pylint: disable=invalid-name  # Hyphenated CLI filename is intentional.

from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

ROW = dict[str, Any]
RUN_FIELDS = (
    "id",
    "name",
    "path",
    "workflow_id",
    "event",
    "head_sha",
    "head_branch",
    "created_at",
    "run_attempt",
    "status",
    "conclusion",
    "actor",
)
JOB_FIELDS = (
    "id",
    "name",
    "status",
    "conclusion",
    "started_at",
    "completed_at",
    "labels",
    "runner_name",
    "runner_group_name",
)


def stamp(value: str) -> datetime:
    """Parse an ISO timestamp; require an explicit timezone."""
    if not isinstance(value, str):
        raise TypeError("timestamp must be a string")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamps must include a timezone")
    return result.astimezone(timezone.utc)


def save(path: Path, value: Any) -> None:
    """Atomically checkpoint JSON in a caller-owned, local directory."""
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


class BudgetExceeded(RuntimeError):
    """Collection stopped at a time or rate limit, with partial data retained."""


class API:
    """Bounded GET-only gh client with durable per-page response caching."""

    def __init__(self, output: Path, seconds: float) -> None:
        self.cache = output / "cache"
        self.cache.mkdir(parents=True, exist_ok=True)
        self.deadline = time.monotonic() + seconds
        self.lock = threading.Lock()
        self.next_request = 0.0
        self.stopped = ""
        self.requests = 0

    def get(self, endpoint: str) -> Any:
        """GET a page, reuse checkpoints, and stop before exhausting API quota."""
        key = hashlib.sha256(endpoint.encode()).hexdigest()
        path = self.cache / f"{key}.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))["body"]
        with self.lock:
            if self.stopped or time.monotonic() >= self.deadline - 1:
                raise BudgetExceeded(self.stopped or "wall-clock API budget exhausted")
            # At most four requests/sec across workers, below secondary limits.
            delay = max(0.0, self.next_request - time.monotonic())
            if time.monotonic() + delay >= self.deadline:
                raise BudgetExceeded("wall-clock API budget exhausted")
            time.sleep(delay)
            self.next_request = time.monotonic() + 0.25
            self.requests += 1
        timeout = min(30.0, max(0.1, self.deadline - time.monotonic()))
        try:
            result = subprocess.run(
                ["gh", "api", "--method", "GET", "--include", endpoint],
                capture_output=True,
                text=True,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise BudgetExceeded("API request timed out") from error
        header, separator, body = result.stdout.replace("\r\n", "\n").partition("\n\n")
        headers = dict(
            line.lower().split(":", 1) for line in header.splitlines() if ":" in line
        )
        if result.returncode:
            # Do not copy stderr, which can include authenticated URLs, to reports.
            status = header.splitlines()[0] if header else "no HTTP response"
            if "403" in status or "429" in status:
                self.stopped = f"rate/access limit: {status}; no automatic retry"
            raise BudgetExceeded(f"GET failed: {endpoint}: {status}")
        if not separator:
            raise BudgetExceeded("missing API response headers")
        if int(headers.get("x-ratelimit-remaining", "5000")) < 100:
            self.stopped = "primary API quota reserve reached (100 requests)"
        parsed = json.loads(body)
        save(path, {"endpoint": endpoint, "body": parsed})
        return parsed

    def pages(self, endpoint: str, field: str | None = None) -> list[ROW]:
        """Fetch every page; an interrupted list is never marked complete."""
        rows: list[ROW] = []
        page = 1
        while True:
            joiner = "&" if "?" in endpoint else "?"
            data = self.get(f"{endpoint}{joiner}per_page=100&page={page}")
            batch = data[field] if field else data
            rows.extend(batch)
            if len(batch) < 100:
                return rows
            page += 1


def list_runs(api: API, repo: str, start: datetime, end: datetime) -> list[ROW]:
    """Split capped searches recursively; never silently accept the 1,000 cap."""
    query = urlencode({"created": f"{start.isoformat()}..{end.isoformat()}"})
    endpoint = f"/repos/{repo}/actions/runs?{query}"
    first = api.get(f"{endpoint}&per_page=100&page=1")
    if first["total_count"] >= 1000:
        if (end - start).total_seconds() <= 1:
            raise BudgetExceeded(f"unsplittable 1,000-run search cap: {repo}")
        middle = start + timedelta(seconds=int((end - start).total_seconds() / 2))
        rows = list_runs(api, repo, start, middle) + list_runs(api, repo, middle, end)
    else:
        rows = api.pages(endpoint, "workflow_runs")
    return list(
        {
            row["id"]: row for row in rows if start <= stamp(row["created_at"]) < end
        }.values()
    )


def runner_kind(job: ROW) -> tuple[str, int | None]:
    """Classify standard hosted labels conservatively; larger/custom is unknown."""
    labels = [str(label).lower() for label in job.get("labels", [])]
    if "self-hosted" in labels:
        return "self-hosted", None
    standard = {
        "ubuntu-latest": ("linux", 1),
        "ubuntu-22.04": ("linux", 1),
        "ubuntu-24.04": ("linux", 1),
        "ubuntu-26.04": ("linux", 1),
        "ubuntu-22.04-arm": ("linux", 1),
        "ubuntu-24.04-arm": ("linux", 1),
        "ubuntu-26.04-arm": ("linux", 1),
        "windows-latest": ("windows", 2),
        "windows-2022": ("windows", 2),
        "windows-2025": ("windows", 2),
        "macos-latest": ("macos", 10),
        "macos-13": ("macos", 10),
        "macos-14": ("macos", 10),
        "macos-15": ("macos", 10),
        "macos-15-intel": ("macos", 10),
        "macos-26": ("macos", 10),
    }
    for label in labels:
        if label in standard:
            return standard[label]
    return "unknown", None


def empty_metrics() -> ROW:
    """Create independent aggregation counters."""
    return {
        "jobs": 0,
        "timed_jobs": 0,
        "skipped_jobs": 0,
        "unknown_time_jobs": 0,
        "wall_seconds": 0.0,
        "rounded_job_minutes": 0,
        "estimated_private_plan_minutes": 0,
        "public_free_rounded_minutes": 0,
        "unknown_billing_rounded_minutes": 0,
        "self_hosted_rounded_minutes": 0,
    }


def job_metrics(job: ROW, private: bool | None, end: datetime) -> ROW:
    """Separate elapsed, rounded, free and estimated plan minutes; never invoice."""
    metrics = empty_metrics()
    metrics["jobs"] = 1
    if job.get("conclusion") == "skipped":
        metrics["skipped_jobs"] = 1
        return metrics
    try:
        started = stamp(job["started_at"])
        completed = stamp(job["completed_at"])
        if completed < started or completed > end:
            raise ValueError("invalid or post-snapshot interval")
    except (KeyError, TypeError, ValueError):
        metrics["unknown_time_jobs"] = 1
        return metrics
    seconds = (completed - started).total_seconds()
    rounded = math.ceil(seconds / 60)
    metrics.update(timed_jobs=1, wall_seconds=seconds, rounded_job_minutes=rounded)
    kind, multiplier = runner_kind(job)
    if kind == "self-hosted":
        metrics["self_hosted_rounded_minutes"] = rounded
    elif multiplier is None or private is None:
        metrics["unknown_billing_rounded_minutes"] = rounded
    elif private:
        metrics["estimated_private_plan_minutes"] = rounded * multiplier
    else:
        metrics["public_free_rounded_minutes"] = rounded
    return metrics


def add_metrics(target: ROW, source: ROW) -> None:
    """Sum only measurement counters."""
    for key in empty_metrics():
        target[key] += source[key]


def aggregate(state: ROW) -> ROW:
    """Aggregate cached attempts without treating missing attempts as zero usage."""
    workflows: dict[str, ROW] = {}
    jobs: dict[str, ROW] = {}
    end = stamp(state["end"])
    for repo, data in state["repositories"].items():
        for run in data.get("runs", []):
            key = f"{repo}:{run.get('workflow_id', run['name'])}"
            if key not in workflows:
                workflows[key] = {
                    **empty_metrics(),
                    "repo": repo,
                    "workflow": run["name"],
                    "path": run.get("path"),
                    "runs": 0,
                    "expected_attempts": 0,
                    "fetched_attempts": 0,
                    "complete_runs": 0,
                    "triggers": Counter(),
                    "first": empty_metrics(),
                    "retries": empty_metrics(),
                    "jobs_per_attempt": [],
                    "renovate_runs": 0,
                    "renovate_unique_branches": set(),
                    "commit_events": {},
                }
            workflow = workflows[key]
            workflow["runs"] += 1
            expected = run.get("run_attempt", 1)
            workflow["expected_attempts"] += expected
            workflow["triggers"][run["event"]] += 1
            events = workflow["commit_events"].setdefault(run["head_sha"], set())
            events.add(run["event"])
            branch = run.get("head_branch") or ""
            actor = run.get("actor", {}).get("login", "")
            if branch.startswith("renovate/") or "renovate" in actor.lower():
                workflow["renovate_runs"] += 1
                workflow["renovate_unique_branches"].add(branch)
            attempts = data.get("attempts", {}).get(str(run["id"]), {})
            workflow["complete_runs"] += all(
                str(number) in attempts for number in range(1, expected + 1)
            )
            for number in range(1, expected + 1):
                if str(number) not in attempts:
                    continue
                workflow["fetched_attempts"] += 1
                batch = attempts[str(number)]
                workflow["jobs_per_attempt"].append(len(batch))
                for job in batch:
                    metrics = job_metrics(job, data.get("private"), end)
                    add_metrics(workflow, metrics)
                    add_metrics(
                        workflow["first" if number == 1 else "retries"], metrics
                    )
                    job_key = f"{key}:{job['name']}"
                    if job_key not in jobs:
                        jobs[job_key] = {
                            **empty_metrics(),
                            "repo": repo,
                            "workflow": run["name"],
                            "job": job["name"],
                            "first": empty_metrics(),
                            "retries": empty_metrics(),
                            "runner_kinds": Counter(),
                        }
                    add_metrics(jobs[job_key], metrics)
                    add_metrics(
                        jobs[job_key]["first" if number == 1 else "retries"], metrics
                    )
                    jobs[job_key]["runner_kinds"][runner_kind(job)[0]] += 1
    for workflow in workflows.values():
        workflow["renovate_unique_branches"] = len(workflow["renovate_unique_branches"])
        workflow["push_pr_shared_shas"] = sum(
            {"push", "pull_request"} <= events
            for events in workflow.pop("commit_events").values()
        )
        counts = workflow.pop("jobs_per_attempt")
        workflow["jobs_per_attempt_max"] = max(counts, default=0)
        workflow["jobs_per_attempt_mean"] = (
            sum(counts) / len(counts) if counts else None
        )
        complete = workflow["complete_runs"] == workflow["runs"]
        workflow["wall_minutes_per_run"] = (
            workflow["wall_seconds"] / 60 / workflow["runs"] if complete else None
        )
    return {
        "start": state["start"],
        "end": state["end"],
        "workflows": sorted(workflows.values(), key=lambda row: -row["wall_seconds"]),
        "jobs": sorted(jobs.values(), key=lambda row: -row["wall_seconds"]),
    }


def recover_runs(api: API, repo: str, start: datetime, end: datetime) -> list[ROW]:
    """Recover observed runs from pages of an interrupted, incomplete listing."""
    rows: dict[int, ROW] = {}
    for path in api.cache.glob("*.json"):
        page = json.loads(path.read_text(encoding="utf-8"))
        if not page["endpoint"].startswith(f"/repos/{repo}/actions/runs?"):
            continue
        for row in page["body"].get("workflow_runs", []):
            if start <= stamp(row["created_at"]) < end:
                previous = rows.get(row["id"], {})
                if row.get("run_attempt", 1) >= previous.get("run_attempt", 1):
                    rows[row["id"]] = row
    return list(rows.values())


def collect(api: API, state: ROW, checkpoint: Path, jobs_only: bool = False) -> None:
    """Inventory all repos first, then fetch explicit attempts fairly across repos."""
    start, end = stamp(state["start"]), stamp(state["end"])
    lock = threading.Lock()

    def inventory(item: tuple[str, ROW]) -> None:
        repo, data = item
        if data.get("listing_complete"):
            return
        try:
            rows = list_runs(api, repo, start, end)
            data["runs"] = [{key: row.get(key) for key in RUN_FIELDS} for row in rows]
            data["listing_complete"] = True
            data.pop("error", None)
        except BudgetExceeded as error:
            data["error"] = str(error)
            rows = recover_runs(api, repo, start, end)
            data["runs"] = [{key: row.get(key) for key in RUN_FIELDS} for row in rows]
        with lock:
            save(checkpoint, state)

    original_deadline = api.deadline
    if not jobs_only:
        # Reserve half the remaining time for jobs even if a repo has a run storm.
        api.deadline = time.monotonic() + (api.deadline - time.monotonic()) / 2
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(inventory, state["repositories"].items()))
        api.deadline = original_deadline
    queues = []
    for repo, data in state["repositories"].items():
        rows = sorted(
            data.get("runs", []), key=lambda row: row["created_at"], reverse=True
        )
        # Sample each workflow before its next run; observer volume must not
        # starve expensive but less frequent build/test workflows of coverage.
        occurrences: Counter[Any] = Counter()
        ranked = []
        for position, run in enumerate(rows):
            workflow = run.get("workflow_id", run["name"])
            ranked.append((occurrences[workflow], position, run))
            occurrences[workflow] += 1
        rows = [run for _, _, run in sorted(ranked, key=lambda item: item[:2])]
        queues.append([(repo, run) for run in rows])
    # Round-robin repo ordering avoids exhausting the budget on one large repo.
    pending = [
        queue[index]
        for index in range(max(map(len, queues), default=0))
        for queue in queues
        if index < len(queue)
    ]

    def attempts(item: tuple[str, ROW]) -> None:
        repo, run = item
        data = state["repositories"][repo]
        for number in range(1, run.get("run_attempt", 1) + 1):
            with lock:
                existing = data.setdefault("attempts", {}).setdefault(
                    str(run["id"]), {}
                )
                if str(number) in existing:
                    continue
            endpoint = f"/repos/{repo}/actions/runs/{run['id']}/attempts/{number}/jobs"
            try:
                batch = api.pages(endpoint, "jobs")
            except BudgetExceeded as error:
                with lock:
                    data["jobs_error"] = str(error)
                return
            with lock:
                existing[str(number)] = [
                    {key: job.get(key) for key in JOB_FIELDS} for job in batch
                ]
                # Pages are already durable; state every 20 requests limits IO.
                if api.requests % 20 == 0:
                    save(checkpoint, state)

    with ThreadPoolExecutor(max_workers=4) as pool:
        # Bounded batches avoid queuing thousands of tasks after the deadline.
        for offset in range(0, len(pending), 20):
            if time.monotonic() >= api.deadline or api.stopped:
                break
            list(pool.map(attempts, pending[offset : offset + 20]))
            save(checkpoint, state)
    state["last_collection"] = {
        "requests": api.requests,
        "stopped": api.stopped
        or ("wall-clock budget" if time.monotonic() >= api.deadline else "finished"),
        "at": datetime.now(timezone.utc).isoformat(),
    }
    save(checkpoint, state)


def main() -> int:
    """Collect or reaggregate local checkpoints; incomplete coverage exits 2."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", default=[])
    parser.add_argument("--private-org")
    parser.add_argument("--start", required=True)
    parser.add_argument("--end", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--api-seconds", type=float, default=720)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument(
        "--jobs-only",
        action="store_true",
        help="resume jobs from the existing run inventory",
    )
    args = parser.parse_args()
    start, end = stamp(args.start), stamp(args.end)
    if start >= end or not 0 < args.api_seconds <= 720:
        parser.error("require start < end and 0 < api-seconds <= 720")
    args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
    checkpoint = args.output / "checkpoint.json"
    state: ROW = (
        json.loads(checkpoint.read_text())
        if checkpoint.exists()
        else {
            "start": start.isoformat(),
            "end": end.isoformat(),
            "repositories": {},
        }
    )
    if (state["start"], state["end"]) != (start.isoformat(), end.isoformat()):
        parser.error("checkpoint date window differs; use a new output directory")
    if not args.offline:
        api = API(args.output, args.api_seconds)
        state.pop("collection_error", None)
        try:
            if args.private_org:
                repos = api.pages(f"/orgs/{args.private_org}/repos?type=all")
                state["org_inventory"] = {
                    "org": args.private_org,
                    "visible_repositories": len(repos),
                    "private_repositories": sum(repo["private"] for repo in repos),
                    "visibility_note": "Only repositories visible to the credential",
                }
                for repo in repos:
                    if repo["private"] or repo["full_name"] in args.repo:
                        state["repositories"].setdefault(
                            repo["full_name"], {"private": repo["private"]}
                        )
            for repo in args.repo:
                if repo not in state["repositories"]:
                    metadata = api.get(f"/repos/{repo}")
                    state["repositories"][repo] = {"private": metadata["private"]}
            save(checkpoint, state)
            collect(api, state, checkpoint, jobs_only=args.jobs_only)
        except BudgetExceeded as error:
            state["collection_error"] = str(error)
            save(checkpoint, state)
    result = aggregate(state)
    save(args.output / "measurements.json", result)
    complete = (
        not state.get("collection_error")
        and bool(state["repositories"])
        and all(
            data.get("listing_complete")
            and all(
                all(
                    str(number) in data.get("attempts", {}).get(str(run["id"]), {})
                    for number in range(1, run.get("run_attempt", 1) + 1)
                )
                for run in data.get("runs", [])
            )
            for data in state["repositories"].values()
        )
    )
    print(
        json.dumps(
            {
                "complete": complete,
                "workflows": len(result["workflows"]),
                "output": str(args.output),
            }
        )
    )
    return 0 if complete else 2


if __name__ == "__main__":
    raise SystemExit(main())
