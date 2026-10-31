#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only, resumable Actions measurement; see docs/actions/measurement.md.

Only GET requests are made. API responses/checkpoints can contain private metadata;
keep the output directory outside the repository. No logs or secrets are fetched.
"""

# pylint: disable=invalid-name  # Hyphenated CLI filename is intentional.

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, TypeGuard
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
# Standalone script library is added to the search path above.
# pylint: disable-next=wrong-import-position
from actions_metrics import (  # noqa: E402
    add_metrics,
    empty_metrics,
    job_metrics,
    runner_kind,
    stamp,
)

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
    "updated_at",
    "_observed_at",
    "run_attempt",
    "status",
    "conclusion",
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


def save(path: Path, value: Any) -> None:
    """Atomically checkpoint JSON in a caller-owned, local directory."""
    descriptor, name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(json.dumps(value, indent=2) + "\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def output_directory(output: Path) -> Path:
    """Create only the output root before taking ownership of its contents."""
    output = output.resolve()
    if any((parent / ".git").exists() for parent in (output, *output.parents)):
        raise ValueError("output must be outside every git checkout")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    return output


class OutputInUse(RuntimeError):
    """Another process owns this output; its collection status is unknown."""


@contextmanager
def output_ownership(output: Path) -> Iterator[None]:
    """Fail immediately on contention; closing the descriptor releases ownership."""
    # Keep this inode across invocations: unlinking it could let a new process
    # lock a replacement while another process still owns the original inode.
    with os.fdopen(
        os.open(output / ".collector.lock", os.O_WRONLY | os.O_CREAT, 0o600),
        "w",
        encoding="utf-8",
    ) as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise OutputInUse(
                "output directory is already in use; collection status unknown; "
                "retry after the owning invocation exits"
            ) from error
        os.fchmod(lock.fileno(), 0o600)
        yield


def prepare_output(output: Path) -> Path:
    """Keep private metadata out of checkouts and restrict existing outputs too."""
    output = output_directory(output)
    output.chmod(0o700)
    for name in ("checkpoint.json", "measurements.json"):
        if (output / name).exists():
            (output / name).chmod(0o600)
    cache = output / "cache"
    if cache.exists():
        restrict_cache(cache)
    return output


def restrict_cache(cache: Path) -> None:
    """Restrict endpoint directories, current pages and legacy flat cache files."""
    cache.chmod(0o700)
    for path in cache.rglob("*"):
        if path.is_dir():
            path.chmod(0o700)
        elif path.suffix == ".json":
            path.chmod(0o600)


class BudgetExceeded(RuntimeError):
    """Collection stopped at a time or rate limit, with partial data retained."""


def page_rows(data: Any, field: str | None = None) -> list[ROW]:
    """Reject malformed list payloads before callers interpret individual rows."""
    if field:
        if not isinstance(data, dict) or field not in data:
            raise BudgetExceeded("missing API page field")
        data = data[field]
    if not isinstance(data, list) or any(not isinstance(row, dict) for row in data):
        raise BudgetExceeded("invalid API page list")
    return data


def valid_count(value: Any, minimum: int = 0) -> TypeGuard[int]:
    """Accept integer API counts, excluding booleans despite their int ancestry."""
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def inventory_page(data: Any, field: str | None, cursor: ROW) -> list[ROW]:
    """Validate counted inventories before advancing a durable pagination cursor."""
    batch = page_rows(data, field)
    if field in ("workflow_runs", "jobs"):
        count = data.get("total_count")
        if not valid_count(count):
            raise BudgetExceeded(f"invalid API {field} total_count")
        if any(not valid_count(row.get("id")) for row in batch):
            raise BudgetExceeded(f"invalid API {field} id")
        previous_count = cursor.setdefault("total_count", count)
        cursor["changed"] = cursor.get("changed", False) or previous_count != count
    return batch


class API:
    """Bounded GET-only gh client with durable per-page response caching."""

    def __init__(self, output: Path, seconds: float) -> None:
        self.cache = output / "cache"
        self.cache.mkdir(parents=True, exist_ok=True, mode=0o700)
        restrict_cache(self.cache)
        self.deadline = time.monotonic() + seconds
        self.lock = threading.Lock()
        self.pacing_lock = threading.Lock()
        self.next_request = 0.0
        self.stopped = ""
        self.requests = 0

    def cache_group(self, endpoint: str) -> Path:
        """Group query variants by exact route, without parsing response bodies."""
        route = endpoint.partition("?")[0]
        return self.cache / hashlib.sha256(route.encode()).hexdigest()

    def invalidate(self, prefix: str) -> None:
        """Discard mutable pages before rebuilding a listing or unfinished attempt."""
        with self.lock:
            # Enumerate only this route: gaps and split-window queries cannot
            # leave stale higher pages behind. Legacy flat pages are never read.
            for path in self.cache_group(prefix).glob("*.json"):
                path.unlink()

    def discard_page(self, endpoint: str) -> None:
        """Allow a rejected response to be refetched without losing earlier pages."""
        key = hashlib.sha256(endpoint.encode()).hexdigest()
        with self.lock:
            (self.cache_group(endpoint) / f"{key}.json").unlink(missing_ok=True)

    def admit(self) -> float:
        """Pace globally without blocking responses from publishing a stop."""
        with self.pacing_lock:
            with self.lock:
                if self.stopped or time.monotonic() >= self.deadline - 1:
                    raise BudgetExceeded(
                        self.stopped or "wall-clock API budget exhausted",
                    )
                delay = max(0.0, self.next_request - time.monotonic())
                if time.monotonic() + delay >= self.deadline:
                    raise BudgetExceeded("wall-clock API budget exhausted")
            time.sleep(delay)
            # This is the admission point, serialized with stop publication.
            # The separate pacing lock keeps all workers below four requests/sec.
            with self.lock:
                now = time.monotonic()
                if self.stopped or now >= self.deadline - 1:
                    raise BudgetExceeded(
                        self.stopped or "wall-clock API budget exhausted",
                    )
                self.next_request = now + 0.25
                self.requests += 1
                return min(30.0, self.deadline - now)

    def get(self, endpoint: str) -> Any:
        """GET a page, reuse checkpoints, and stop before exhausting API quota."""
        key = hashlib.sha256(endpoint.encode()).hexdigest()
        path = self.cache_group(endpoint) / f"{key}.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))["body"]
        timeout = self.admit()
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
            (line.lower().split(":", 1) for line in header.splitlines() if ":" in line),
        )
        if result.returncode:
            # Do not copy stderr, which can include authenticated URLs, to reports.
            status = header.splitlines()[0] if header else "no HTTP response"
            if "403" in status or "429" in status:
                with self.lock:
                    self.stopped = f"rate/access limit: {status}; no automatic retry"
            raise BudgetExceeded(f"GET failed: {endpoint}: {status}")
        if not separator:
            raise BudgetExceeded("missing API response headers")
        try:
            if int(headers.get("x-ratelimit-remaining", "5000")) < 100:
                with self.lock:
                    self.stopped = "primary API quota reserve reached (100 requests)"
            parsed = json.loads(body)
        except ValueError as error:
            raise BudgetExceeded("invalid API response or quota header") from error
        # Persist observation time with each run, never the time a cached page
        # is replayed. Legacy rows may still have only the API's updated_at.
        if isinstance(parsed, dict) and isinstance(parsed.get("workflow_runs"), list):
            for row in parsed["workflow_runs"]:
                if isinstance(row, dict):
                    row["_observed_at"] = datetime.now(timezone.utc).isoformat()
        path.parent.mkdir(mode=0o700, exist_ok=True)
        save(path, {"endpoint": endpoint, "body": parsed})
        return parsed

    def pages(self, endpoint: str, field: str | None = None) -> list[ROW]:
        """Persist the cursor and rows of a pass; only its owner starts a refresh."""
        key = hashlib.sha256(endpoint.encode()).hexdigest()
        progress = self.cache_group(endpoint) / f"{key}.progress.json"
        cursor: ROW = (
            json.loads(progress.read_text(encoding="utf-8"))
            if progress.exists()
            else {"rows": [], "page": 1, "complete": False}
        )
        rows: list[ROW] = cursor["rows"]
        page = cursor["page"]
        if cursor["complete"]:
            return rows
        joiner = "&" if "?" in endpoint else "?"
        counted_inventory = field in ("workflow_runs", "jobs")
        if counted_inventory and page > 1 and "total_count" not in cursor:
            # Adopt older cursors using their original, cached inventory count.
            first_endpoint = f"{endpoint}{joiner}per_page=100&page=1"
            try:
                inventory_page(self.get(first_endpoint), field, cursor)
            except BudgetExceeded:
                self.discard_page(first_endpoint)
                raise
        while True:
            page_endpoint = f"{endpoint}{joiner}per_page=100&page={page}"
            data = self.get(page_endpoint)
            try:
                batch = inventory_page(data, field, cursor)
            except BudgetExceeded:
                self.discard_page(page_endpoint)
                raise
            rows.extend(batch)
            progress.parent.mkdir(mode=0o700, exist_ok=True)
            cursor.update(rows=rows, page=page + 1, complete=len(batch) < 100)
            if (
                cursor["complete"]
                and counted_inventory
                and (
                    cursor["changed"]
                    or len({row["id"] for row in rows}) != cursor["total_count"]
                    or len(rows) != cursor["total_count"]
                )
            ):
                # Mutable inventories can shift unseen rows behind saved offsets
                # or repeat observed IDs. Reconcile against a fresh
                # inventory before claiming coverage. Its cursor is durable too;
                # stable inventories never repeat pages just because time ran out.
                save(
                    progress.with_suffix(".observed.json"),
                    {"endpoint": endpoint, "body": {field: rows}},
                )
                for old_page in range(1, page + 1):
                    self.discard_page(f"{endpoint}{joiner}per_page=100&page={old_page}")
                save(progress, {"rows": [], "page": 1, "complete": False})
                raise BudgetExceeded(
                    f"{field} inventory changed; reconciliation pending",
                )
            save(progress, cursor)
            if len(batch) < 100:
                return rows
            page += 1


def run_snapshot_key(row: ROW) -> tuple[int, datetime, bool, str]:
    """Order attempts, API freshness (observation fallback), then cautious status."""
    freshness = datetime.min.replace(tzinfo=timezone.utc)
    for field in ("updated_at", "_observed_at"):
        try:
            freshness = stamp(row[field])
            break
        except (KeyError, TypeError, ValueError):
            continue
    # With tied/unknown freshness, active evidence must not become terminal
    # merely because its page was enumerated first. Canonical JSON breaks any
    # remaining metadata ties without relying on page/file iteration order.
    return (
        row.get("run_attempt", 1),
        freshness,
        row.get("status") != "completed",
        json.dumps(row, sort_keys=True),
    )


def merge_runs(rows: list[ROW]) -> list[ROW]:
    """Keep each run's highest attempt and freshest snapshot deterministically."""
    runs: dict[int, ROW] = {}
    for row in rows:
        previous = runs.get(row["id"])
        if previous is None or run_snapshot_key(row) > run_snapshot_key(previous):
            runs[row["id"]] = row
    return list(runs.values())


def list_runs(api: API, repo: str, start: datetime, end: datetime) -> list[ROW]:
    """Split capped searches recursively; never silently accept the 1,000 cap."""
    query = urlencode({"created": f"{start.isoformat()}..{end.isoformat()}"})
    endpoint = f"/repos/{repo}/actions/runs?{query}"
    first_endpoint = f"{endpoint}&per_page=100&page=1"
    first = api.get(first_endpoint)
    try:
        count = first.get("total_count") if isinstance(first, dict) else None
        if not valid_count(count):
            raise BudgetExceeded("invalid API run total_count")
        page_rows(first, "workflow_runs")
    except BudgetExceeded:
        api.discard_page(first_endpoint)
        raise
    if count >= 1000:
        if (end - start).total_seconds() <= 1:
            raise BudgetExceeded(f"unsplittable 1,000-run search cap: {repo}")
        middle = start + timedelta(seconds=int((end - start).total_seconds() / 2))
        if not start < middle < end:
            raise BudgetExceeded(f"unsplittable 1,000-run search cap: {repo}")
        rows = list_runs(api, repo, start, middle) + list_runs(api, repo, middle, end)
    else:
        rows = api.pages(endpoint, "workflow_runs")
    try:
        runs = []
        for row in rows:
            if start <= stamp(row["created_at"]) < end:
                runs.append(row)
        if any(not valid_count(row.get("run_attempt"), 1) for row in runs):
            raise ValueError("invalid run attempt")
        return merge_runs(runs)
    except (KeyError, TypeError, ValueError) as error:
        # Row validation sees the aggregate cursor, so rebuild this listing.
        api.invalidate(endpoint)
        raise BudgetExceeded("invalid API run list") from error


def attempt_finished(jobs: list[ROW]) -> bool:
    """Empty terminal attempts and skipped jobs are valid; active jobs are mutable."""
    for job in jobs:
        if job.get("conclusion") == "skipped":
            continue
        if job.get("status", "completed") != "completed" or not job.get("completed_at"):
            return False
    return True


def run_complete(run: ROW, attempts: ROW, terminal_attempts: ROW) -> bool:
    """Require every attempt to have been fetched after it became immutable."""
    return run.get("status") == "completed" and all(
        terminal_attempts.get(str(number)) is True
        and str(number) in attempts
        and attempt_finished(attempts[str(number)])
        for number in range(1, run.get("run_attempt", 1) + 1)
    )


def record_run(workflow: ROW, run: ROW, attempts: ROW, terminal_attempts: ROW) -> None:
    """Count run metadata independently of fetched job timing."""
    workflow["runs"] += 1
    workflow["expected_attempts"] += run.get("run_attempt", 1)
    workflow["triggers"][run["event"]] += 1
    workflow["commit_events"].setdefault(run["head_sha"], set()).add(run["event"])
    branch = run.get("head_branch") or ""
    actor = (run.get("actor") or {}).get("login") or ""
    if branch.startswith("renovate/") or "renovate" in actor.lower():
        workflow["renovate_runs"] += 1
        workflow["renovate_unique_branches"].add(branch)
    workflow["complete_runs"] += run_complete(run, attempts, terminal_attempts)


def record_attempt(
    workflow: ROW,
    jobs: dict[str, ROW],
    batch: list[ROW],
    number: int,
    end: datetime,
) -> None:
    """Sum one explicit attempt into workflow and named-job counters."""
    workflow["fetched_attempts"] += 1
    workflow["jobs_per_attempt"].append(len(batch))
    for job in batch:
        metrics = job_metrics(job, workflow["private"], end)
        add_metrics(workflow, metrics)
        add_metrics(workflow["first" if number == 1 else "retries"], metrics)
        job_key = f"{workflow['workflow_key']}:{job['name']}"
        if job_key not in jobs:
            jobs[job_key] = {
                **empty_metrics(),
                "repo": workflow["repo"],
                "workflow": workflow["workflow"],
                "job": job["name"],
                "first": empty_metrics(),
                "retries": empty_metrics(),
                "runner_kinds": Counter(),
            }
        add_metrics(jobs[job_key], metrics)
        add_metrics(jobs[job_key]["first" if number == 1 else "retries"], metrics)
        jobs[job_key]["runner_kinds"][runner_kind(job)[0]] += 1


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
                    "private": data.get("private"),
                    "workflow": run["name"],
                    "workflow_key": key,
                    "path": run.get("path"),
                    "listing_complete": data.get("listing_complete", False),
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
            run_id = str(run["id"])
            attempts = data.get("attempts", {}).get(run_id, {})
            record_run(
                workflow,
                run,
                attempts,
                data.get("terminal_attempts", {}).get(run_id, {}),
            )
            for number in range(1, run.get("run_attempt", 1) + 1):
                if str(number) not in attempts:
                    continue
                record_attempt(
                    workflow,
                    jobs,
                    attempts[str(number)],
                    number,
                    end,
                )
    for workflow in workflows.values():
        workflow["renovate_unique_branches"] = len(workflow["renovate_unique_branches"])
        workflow["push_pr_shared_shas"] = sum(
            (
                {"push", "pull_request"} <= events
                for events in workflow.pop("commit_events").values()
            ),
        )
        counts = workflow.pop("jobs_per_attempt")
        workflow["jobs_per_attempt_max"] = max(counts, default=0)
        mean = sum(counts) / len(counts) if counts else None
        workflow["jobs_per_attempt_mean"] = mean
        workflow.pop("workflow_key")
        complete = (
            workflow["listing_complete"]
            and workflow["complete_runs"] == workflow["runs"]
            and not workflow["unknown_time_jobs"]
        )
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
    with api.lock:
        for path in api.cache_group(f"/repos/{repo}/actions/runs").glob("*.json"):
            try:
                page = json.loads(path.read_text(encoding="utf-8"))
                batch = page_rows(page["body"], "workflow_runs")
                for row in batch:
                    attempt = row.get("run_attempt")
                    if not valid_count(attempt, 1):
                        continue
                    if start <= stamp(row["created_at"]) < end:
                        prior = rows.get(row["id"], {})
                        if not prior or run_snapshot_key(row) > run_snapshot_key(prior):
                            rows[row["id"]] = row
            except (BudgetExceeded, KeyError, TypeError, ValueError):
                # Recovery is best effort; malformed pages cannot restore coverage.
                continue
    return list(rows.values())


def pending_runs(state: ROW) -> list[tuple[str, ROW]]:
    """Round-robin repositories and workflows without starving smaller cohorts."""
    queues = []
    for repo, data in state["repositories"].items():
        rows = sorted(
            data.get("runs", []),
            key=lambda row: row["created_at"],
            reverse=True,
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
    return [
        queue[index]
        for index in range(max(map(len, queues), default=0))
        for queue in queues
        if index < len(queue)
    ]


def fetch_attempts(
    api: API, state: ROW, checkpoint: Path, lock: Any, item: tuple[str, ROW]
) -> None:
    """Resume terminal pagination; refresh pages first observed while mutable."""
    # pylint: disable=too-many-locals  # Cursor and terminal provenance are distinct.
    repo, run = item
    data = state["repositories"][repo]
    for number in range(1, run.get("run_attempt", 1) + 1):
        with lock:
            saved = data.setdefault("attempts", {}).setdefault(str(run["id"]), {})
            terminal_attempts = data.setdefault("terminal_attempts", {}).setdefault(
                str(run["id"]), {}
            )
            # A later attempt proves earlier attempts immutable. For the latest,
            # observe terminal status BEFORE fetching any pages. If the run
            # finishes during the fetch, conservatively refresh on the next pass.
            terminal = run.get("status") == "completed"
            if number < run.get("run_attempt", 1):
                terminal = True
            if (
                str(number) in saved
                and terminal_attempts.get(str(number)) is True
                and attempt_finished(saved[str(number)])
                and terminal
            ):
                continue
        endpoint = f"/repos/{repo}/actions/runs/{run['id']}/attempts/{number}/jobs"
        with lock:
            progress = data.setdefault("attempt_progress", {}).setdefault(
                str(run["id"]),
                {},
            )
            if not terminal or progress.get(str(number)) is not True:
                api.invalidate(f"{endpoint}?")
            progress[str(number)] = terminal
            save(checkpoint, state)
        try:
            batch = api.pages(endpoint, "jobs")
        except BudgetExceeded as error:
            with lock:
                data["jobs_error"] = str(error)
            return
        with lock:
            saved[str(number)] = [{k: job.get(k) for k in JOB_FIELDS} for job in batch]
            terminal_attempts[str(number)] = terminal
            progress.pop(str(number), None)
            # Pages are already durable; state every 20 requests limits IO.
            if api.requests % 20 == 0:
                save(checkpoint, state)


def collect(api: API, state: ROW, checkpoint: Path, jobs_only: bool = False) -> None:
    """Inventory all repos first, then fetch explicit attempts fairly across repos."""
    start, end = stamp(state["start"]), stamp(state["end"])
    lock = threading.Lock()

    def inventory(item: tuple[str, ROW]) -> None:
        repo, data = item
        update: ROW = {"listing_complete": False}
        with lock:
            # Keep bounded pagination progress; pages checks inventory counts
            # for deletion gaps. Status and retries refresh in the next pass.
            if not data.get("listing_in_progress"):
                api.invalidate(f"/repos/{repo}/actions/runs?")
            data.update(listing_in_progress=True, listing_complete=False)
            save(checkpoint, state)
        try:
            rows = list_runs(api, repo, start, end)
            update["listing_complete"] = True
            update["listing_in_progress"] = False
        except BudgetExceeded as error:
            update["error"] = str(error)
            rows = recover_runs(api, repo, start, end)
        rows = merge_runs([*data.get("runs", []), *rows])
        update["runs"] = [
            {
                **{key: row.get(key) for key in RUN_FIELDS},
                "actor": {"login": (row.get("actor") or {}).get("login")},
            }
            for row in rows
        ]
        with lock:
            data.pop("error", None)
            data.update(update)
            save(checkpoint, state)

    original_deadline = api.deadline
    if not jobs_only:
        # Reserve half the remaining time for jobs even if a repo has a run storm.
        api.deadline = time.monotonic() + (api.deadline - time.monotonic()) / 2
        repositories = list(state["repositories"].items())
        unfinished = [
            item
            for item in repositories
            if not item[1].get("listing_complete")
            or item[1].get("listing_in_progress") is not False
        ]
        try:
            with ThreadPoolExecutor(max_workers=4) as pool:
                # Finish this generation across bounded invocations before
                # reopening completed listings, even if this pass has time left.
                # Legacy listings without cursor provenance also need a pass.
                list(pool.map(inventory, unfinished or repositories))
        finally:
            api.deadline = original_deadline
    for data in state["repositories"].values():
        data.pop("jobs_error", None)
    pending = pending_runs(state)

    with ThreadPoolExecutor(max_workers=4) as pool:
        # Bounded batches avoid queuing thousands of tasks after the deadline.
        for offset in range(0, len(pending), 20):
            if time.monotonic() >= api.deadline or api.stopped:
                break
            list(
                pool.map(
                    lambda item: fetch_attempts(api, state, checkpoint, lock, item),
                    pending[offset : offset + 20],
                )
            )
            save(checkpoint, state)
    state["last_collection"] = {
        "requests": api.requests,
        "stopped": api.stopped
        or (
            "wall-clock budget"
            if time.monotonic() >= api.deadline
            else "finished" if coverage_complete(state) else "coverage gaps"
        ),
        "at": datetime.now(timezone.utc).isoformat(),
    }
    save(checkpoint, state)


def reconcile_org(
    state: ROW,
    org: str,
    repos: list[ROW],
    explicit: list[str],
) -> set[str]:
    """Refresh selected members and distrust prior members missing from a full pass."""
    refreshed = set()
    for repo in repos:
        name = repo["full_name"].lower()
        if repo["private"] or name in explicit or name in state["repositories"]:
            data = state["repositories"].setdefault(name, {})
            data.update(
                private=repo["private"],
                inventory_org=org,
                metadata_source=f"/orgs/{org}/repos",
                inventory_missing=False,
            )
            refreshed.add(name)
    for name, data in state["repositories"].items():
        # Owner matching also reconciles checkpoints predating membership fields.
        if name not in refreshed and (
            data.get("inventory_org") == org or name.partition("/")[0] == org
        ):
            data.update(private=None, inventory_missing=True)
            data.pop("metadata_source", None)
    return refreshed


def discover(api: API, state: ROW, args: argparse.Namespace) -> None:
    """Record optional inventory gaps while continuing independent repositories."""
    errors = []
    refreshed = set()
    if args.private_org:
        try:
            # Keep the durable cursor until a pass finishes; only a subsequent
            # discovery starts a refresh, as with repository run listings.
            if state.get("org_inventory", {}).get("complete"):
                api.invalidate(f"/orgs/{args.private_org}/repos?")
            repos = api.pages(f"/orgs/{args.private_org}/repos?type=all")
            if any(
                not isinstance(repo.get(key), kind)
                for repo in repos
                for key, kind in (("private", bool), ("full_name", str))
            ):
                # This aggregate cursor contains untrusted repository metadata.
                api.invalidate(f"/orgs/{args.private_org}/repos?")
                raise BudgetExceeded("invalid API repository list")
            state["org_inventory"] = {
                "org": args.private_org,
                "complete": True,
                "visible_repositories": len(repos),
                "private_repositories": sum(repo["private"] for repo in repos),
                "visibility_note": "Only repositories visible to the credential",
            }
            refreshed = reconcile_org(state, args.private_org, repos, args.repo)
        except BudgetExceeded as error:
            errors.append(str(error))
            state["org_inventory"] = {
                "org": args.private_org,
                "complete": False,
                "error": str(error),
            }
    for repo in args.repo:
        if repo not in refreshed:
            try:
                api.invalidate(f"/repos/{repo}")
                info = api.get(f"/repos/{repo}")
                private = info.get("private") if isinstance(info, dict) else None
                if not isinstance(private, bool):
                    raise BudgetExceeded("invalid API repository metadata")
                state["repositories"].setdefault(repo, {}).update(
                    private=private,
                    metadata_source=f"/repos/{repo}",
                    inventory_missing=False,
                )
            except BudgetExceeded as error:
                if repo in state["repositories"]:
                    data = state["repositories"][repo]
                    data.update(private=None, inventory_missing=True)
                    data.pop("metadata_source", None)
                errors.append(str(error))
    if errors:
        state["collection_error"] = "; ".join(errors)


def coverage_complete(state: ROW) -> bool:
    """Completion covers listing and terminal attempts, independently of billing."""
    return (
        not state.get("collection_error")
        and state.get("org_inventory", {}).get("complete", True)
        and bool(state["repositories"])
        and all(
            data.get("listing_complete")
            and isinstance(data.get("private"), bool)
            and not data.get("inventory_missing")
            and not data.get("error")
            and not data.get("jobs_error")
            and all(
                run_complete(
                    run,
                    data.get("attempts", {}).get(str(run["id"]), {}),
                    data.get("terminal_attempts", {}).get(str(run["id"]), {}),
                )
                for run in data.get("runs", [])
            )
            for data in state["repositories"].values()
        )
    )


def validate_scope(state: ROW, args: argparse.Namespace) -> None:
    """Normalize online selection and refuse to mix incompatible inventories."""
    args.repo = sorted({repo.strip().strip("/").lower() for repo in args.repo})
    if args.private_org:
        args.private_org = args.private_org.strip().strip("/").lower()
    requested = {"repos": args.repo, "private_org": args.private_org}
    previous = state.get("scope")
    if previous is None:
        # Legacy explicit-only inventories can be adopted only on an exact
        # match. Org selection and partially discovered scopes are ambiguous.
        if state.get("org_inventory") or (
            state["repositories"]
            and (args.private_org or sorted(state["repositories"]) != args.repo)
        ):
            raise ValueError(
                "legacy checkpoint scope is unknown; use a new output directory "
                "or --offline/--jobs-only"
            )
    elif previous != requested:
        raise ValueError("checkpoint scope differs; use a new output directory")
    state["scope"] = requested


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
    if start.microsecond or end.microsecond:
        parser.error("start and end must use whole-second precision")
    if end > datetime.now(timezone.utc):
        parser.error("end must be in the past; open snapshot windows are unsupported")
    try:
        args.output = output_directory(args.output)
    except ValueError as error:
        parser.error(str(error))
    try:
        with output_ownership(args.output):
            prepare_output(args.output)
            status = measure_output(args, start, end, parser)
    except OutputInUse as error:
        parser.error(str(error))
    return status


def measure_output(
    args: argparse.Namespace,
    start: datetime,
    end: datetime,
    parser: argparse.ArgumentParser,
) -> int:
    """Read and update checkpoints and caches only while owning the output."""
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
    if not args.offline and not args.jobs_only:
        try:
            validate_scope(state, args)
        except ValueError as error:
            parser.error(str(error))
    if not args.offline:
        api = API(args.output, args.api_seconds)
        try:
            if not args.jobs_only:
                state.pop("collection_error", None)
                original_deadline = api.deadline
                now = time.monotonic()
                api.deadline = now + (original_deadline - now) / 2
                try:
                    discover(api, state, args)
                finally:
                    api.deadline = original_deadline
            save(checkpoint, state)
            collect(api, state, checkpoint, jobs_only=args.jobs_only)
        except BudgetExceeded as error:
            state["collection_error"] = "; ".join(
                filter(None, (state.get("collection_error"), str(error)))
            )
            save(checkpoint, state)
    result = aggregate(state)
    save(args.output / "measurements.json", result)
    complete = coverage_complete(state)
    workflows = result["workflows"]
    unknown_billing = sum(row["unknown_billing_rounded_minutes"] for row in workflows)
    scope = "checkpoint" if args.offline or args.jobs_only else "requested"
    print(
        json.dumps(
            {
                "complete": complete,
                "workflows": len(result["workflows"]),
                "unknown_time_jobs": sum(row["unknown_time_jobs"] for row in workflows),
                "unknown_billing_rounded_minutes": unknown_billing,
                "scope": scope,
                "output": str(args.output),
            }
        )
    )
    return 0 if complete else 2


if __name__ == "__main__":
    raise SystemExit(main())
