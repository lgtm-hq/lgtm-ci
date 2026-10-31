# SPDX-License-Identifier: MIT
"""Fixture aggregation and bounded, read-only collection regression tests."""

import json
import sys
import threading
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest


@pytest.fixture(name="measurement")
def measurement_module(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the maintenance CLI without running it."""
    return load_script("scripts/ci/maintenance/measure-actions.py")


@pytest.fixture(name="state")
def fixture_state(fixtures_dir: Path) -> dict[str, Any]:
    """API-shaped fixture with private/public jobs and a missing attempt."""
    path = fixtures_dir / "actions/measurement.json"
    result: dict[str, Any] = json.loads(path.read_text())
    for data in result["repositories"].values():
        for run in data["runs"]:
            run["status"] = "completed"
        data["terminal_attempts"] = {
            key: dict.fromkeys(nums, True) for key, nums in data["attempts"].items()
        }
    return result


def test_rounding_attempts_and_missing_coverage(
    measurement: ModuleType, state: dict[str, Any]
) -> None:
    """Round per job before multiplying; missing attempts are never zero usage."""
    result = measurement.aggregate(state)
    workflows = result["workflows"]
    private = next(row for row in workflows if row["repo"] == "example/private")
    assert private["wall_seconds"] == 122
    assert private["rounded_job_minutes"] == 4
    assert private["estimated_private_plan_minutes"] == 14
    assert private["first"]["estimated_private_plan_minutes"] == 4
    assert private["retries"]["estimated_private_plan_minutes"] == 10
    assert private["expected_attempts"] == 3
    assert private["fetched_attempts"] == 2
    assert private["complete_runs"] == 0
    assert private["wall_minutes_per_run"] is None
    assert private["unknown_time_jobs"] == 1
    assert private["skipped_jobs"] == 1
    assert private["triggers"] == {"push": 1, "pull_request": 1}
    assert private["push_pr_shared_shas"] == 1
    assert private["renovate_runs"] == 2
    assert private["renovate_unique_branches"] == 1
    assert private["jobs_per_attempt_max"] == 3
    assert sum(row["wall_seconds"] for row in result["jobs"]) == sum(
        row["wall_seconds"] for row in result["workflows"]
    )


def test_public_free_larger_unknown_and_self_hosted(
    measurement: ModuleType, state: dict[str, Any]
) -> None:
    """Public standard hosted is free; larger and self-hosted remain separate."""
    workflows = measurement.aggregate(state)["workflows"]
    public = next(row for row in workflows if row["repo"] == "example/public")
    assert public["estimated_private_plan_minutes"] == 0
    assert public["public_free_rounded_minutes"] == 2
    assert public["unknown_billing_rounded_minutes"] == 2
    assert public["self_hosted_rounded_minutes"] == 1
    assert public["wall_minutes_per_run"] == pytest.approx(123 / 60)


@pytest.mark.parametrize(
    "change",
    [
        {"completed_at": None},
        {"started_at": "2026-10-03T00:00:00Z"},
        {"completed_at": "2026-11-01T00:00:00Z"},
    ],
)
def test_unknown_intervals_not_fabricated(
    measurement: ModuleType,
    change: dict[str, Any],
) -> None:
    """Incomplete, inverted and post-snapshot intervals are explicit unknowns."""
    job = {
        "started_at": "2026-10-02T00:00:00Z",
        "completed_at": "2026-10-02T00:01:00Z",
        "labels": ["ubuntu-latest"],
        **change,
    }
    result = measurement.job_metrics(
        job,
        True,
        datetime(2026, 10, 31, tzinfo=timezone.utc),
    )
    assert result["wall_seconds"] == 0
    assert result["unknown_time_jobs"] == 1


def test_client_get_cache_and_rate_reserve(
    measurement: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A GET response is durable and low quota stops subsequent network calls."""
    calls: list[Any] = []

    def run(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        calls.append(command)
        return SimpleNamespace(
            returncode=0,
            stdout=('HTTP/2.0 200 OK\r\nX-RateLimit-Remaining: 99\r\n\r\n{"jobs": []}'),
        )

    monkeypatch.setattr(measurement.subprocess, "run", run)
    api = measurement.API(tmp_path, 30)
    legacy = api.cache / f"{measurement.hashlib.sha256(b'/one').hexdigest()}.json"
    measurement.save(legacy, {"endpoint": "/one", "body": {"stale": True}})
    assert api.get("/one") == {"jobs": []}
    assert api.get("/one") == {"jobs": []}
    with pytest.raises(measurement.BudgetExceeded, match="quota"):
        api.get("/two")
    assert calls == [["gh", "api", "--method", "GET", "--include", "/one"]]


@pytest.mark.parametrize("listing", [False, True])
def test_invalidation_touches_only_one_endpoint_including_page_gaps(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    listing: bool,
) -> None:
    """Endpoint directories avoid scanning/parsing unrelated or corrupt pages."""
    # pylint: disable=too-many-locals  # Explicit cache fixtures and guards.
    endpoint = "/repos/example/repo/actions/runs"
    if not listing:
        endpoint += "/1/attempts/1/jobs"
    target = [
        f"{endpoint}?created={window}&per_page=100&page={page}"
        for window, page in (("whole", 1), ("whole", 3), ("split", 2))
    ]
    other = endpoint.replace("example/repo/", "example/other/")
    if not listing:
        other = endpoint.replace("/attempts/1/", "/attempts/11/")
    unrelated = f"{other}?per_page=100&page=1"

    def response(*_args: Any, **_kwargs: Any) -> SimpleNamespace:
        return SimpleNamespace(returncode=0, stdout='HTTP/2.0 200 OK\n\n{"jobs": []}')

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    api = measurement.API(tmp_path, 30)
    for page in [*target, unrelated]:
        api.get(page)
    group = api.cache_group(endpoint)
    unrelated_group = api.cache_group(unrelated)
    unrelated_path = next(unrelated_group.glob("*.json"))
    unrelated_path.write_text("corrupt unrelated page")
    # Prove the directory index works after restarting, without in-memory state.
    api = measurement.API(tmp_path, 30)
    original_glob = Path.glob

    def glob(path: Path, pattern: str) -> Any:
        assert path == group, "invalidation scanned unrelated cache entries"
        return original_glob(path, pattern)

    def parse(*_args: Any, **_kwargs: Any) -> None:
        pytest.fail("invalidation parsed a cached response")

    assert group.stat().st_mode & 0o777 == 0o700
    assert all(path.stat().st_mode & 0o777 == 0o600 for path in group.glob("*.json"))
    with monkeypatch.context() as patch:
        patch.setattr(Path, "glob", glob)
        patch.setattr(measurement.json, "loads", parse)
        api.invalidate(f"{endpoint}?")
    assert not list(group.glob("*.json"))
    assert unrelated_path.read_text() == "corrupt unrelated page"


def test_every_attempt_explicit_and_resume(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Fetch attempt 1/2 explicitly and never call the latest-only jobs route."""
    private = state["repositories"]["example/private"]
    private["runs"] = [private["runs"][0]]
    private["runs"][0]["created_at"] = "2026-10-02T00:00:00Z"
    private["attempts"] = {"1": {"1": []}}
    state["repositories"] = {"example/private": private}
    calls: list[Any] = []

    def pages(endpoint: str, field: str) -> list[dict[str, Any]]:
        calls.append((endpoint, field))
        return []

    api = measurement.API(tmp_path, 30)
    monkeypatch.setattr(api, "pages", pages)
    measurement.collect(api, state, tmp_path / "checkpoint.json", jobs_only=True)
    assert calls == [("/repos/example/private/actions/runs/1/attempts/2/jobs", "jobs")]
    assert private["attempts"]["1"] == {"1": [], "2": []}


@pytest.mark.parametrize("capped_requests", [1, 2])
def test_search_cap_split_and_half_open_dedup(
    measurement: ModuleType,
    capped_requests: int,
) -> None:
    """Split capped searches and deduplicate inclusive API boundaries."""
    start = measurement.stamp("2026-10-01T00:00:00Z")
    end = measurement.stamp("2026-10-03T00:00:00Z")
    boundary = {"id": 1, "created_at": "2026-10-02T00:00:00Z", "run_attempt": 1}
    outside = {"id": 2, "created_at": "2026-10-03T00:00:00Z"}

    class FakeAPI:
        """Return a capped parent with two uncapped inclusive child ranges."""

        count = 0

        def get(self, _endpoint: str) -> dict[str, Any]:
            """Cap only the first request."""
            self.count += 1
            return {
                "total_count": 1000 if self.count <= capped_requests else 2,
                "workflow_runs": [],
            }

        def pages(self, _endpoint: str, _field: str) -> list[dict[str, Any]]:
            """Simulate the inclusive split boundary repeated in both pages."""
            return [boundary, outside]

    assert measurement.list_runs(FakeAPI(), "example/repo", start, end) == [boundary]


def test_expired_budget_makes_no_request(
    measurement: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Deadline enforcement works even if the API has ample quota."""

    def unexpected(*_args: Any, **_kwargs: Any) -> None:
        pytest.fail("network used after deadline")

    monkeypatch.setattr(measurement.subprocess, "run", unexpected)
    api = measurement.API(tmp_path, -1)
    with pytest.raises(measurement.BudgetExceeded, match="budget"):
        api.get("/anything")


def test_interrupted_listing_retains_observed_runs(
    measurement: ModuleType,
    tmp_path: Path,
) -> None:
    """Partial pages survive, without claiming that the search was complete."""
    api = measurement.API(tmp_path, 10)
    endpoint = "/repos/example/repo/actions/runs?created=window"
    group = api.cache_group(endpoint)
    group.mkdir(mode=0o700)
    for number, attempt in enumerate((1, 3)):
        measurement.save(
            group / f"{number}.json",
            {
                "endpoint": endpoint,
                "body": {
                    "workflow_runs": [
                        {
                            "id": 1,
                            "created_at": "2026-10-02T00:00:00Z",
                            "run_attempt": attempt,
                        },
                        {"id": 2, "created_at": "2026-10-31T00:00:00Z"},
                    ]
                },
            },
        )
    rows = measurement.recover_runs(
        api,
        "example/repo",
        measurement.stamp("2026-10-01T00:00:00Z"),
        measurement.stamp("2026-10-31T00:00:00Z"),
    )
    assert len(rows) == 1
    assert rows[0]["run_attempt"] == 3


def test_job_pagination_does_not_stop_at_one_hundred(
    measurement: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An attempt with more than one page includes the final jobs."""
    api = measurement.API(tmp_path, 10)
    calls: list[str] = []

    def get(endpoint: str) -> dict[str, Any]:
        calls.append(endpoint)
        assert len(calls) <= 2, "pagination failed to terminate"
        count = 100 if endpoint.endswith("&page=1") else 1
        return {"jobs": [{"id": i} for i in range(count)]}

    monkeypatch.setattr(api, "get", get)
    assert len(api.pages("/attempts/1/jobs", "jobs")) == 101
    assert len(calls) == 2


def test_failed_org_discovery_never_claims_complete_coverage(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A complete cached repo cannot hide a failure to enumerate private repos."""
    state["repositories"].pop("example/private")
    measurement.save(tmp_path / "checkpoint.json", state)

    def denied(*_args: Any, **_kwargs: Any) -> None:
        raise measurement.BudgetExceeded("organization discovery denied")

    monkeypatch.setattr(measurement.API, "pages", denied)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "measure-actions.py",
            "--private-org",
            "example",
            "--start",
            state["start"],
            "--end",
            state["end"],
            "--output",
            str(tmp_path),
        ],
    )
    assert measurement.main() == 2


@pytest.fixture(name="invoke")
def invoke_main(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> Callable[..., int]:
    """Invoke the CLI with a fixed closed window and caller-owned output."""

    def invoke(*extra: str) -> int:
        monkeypatch.setattr(
            sys,
            "argv",
            [
                "measure-actions.py",
                "--start",
                state["start"],
                "--end",
                state["end"],
                "--output",
                str(tmp_path),
                *extra,
            ],
        )
        return int(measurement.main())

    return invoke


@pytest.mark.parametrize("status", [403, 429])
def test_access_limits_stop_globally_without_retry(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    status: int,
) -> None:
    """An access/rate failure stops all uncached network work, including other repos."""
    calls = []

    def denied(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        calls.append(command[-1])
        return SimpleNamespace(returncode=1, stdout=f"HTTP/2.0 {status} Denied\n\n{{}}")

    monkeypatch.setattr(measurement.subprocess, "run", denied)
    api = measurement.API(tmp_path, 30)
    with pytest.raises(measurement.BudgetExceeded, match="GET failed"):
        api.get("/repos/example/denied")
    with pytest.raises(measurement.BudgetExceeded, match="no automatic retry"):
        api.get("/repos/example/accessible")
    assert calls == ["/repos/example/denied"]


def test_null_actor_and_labels_are_unknown_not_errors(
    measurement: ModuleType,
    state: dict[str, Any],
) -> None:
    """Null API fields survive collection and aggregation without invented billing."""
    public = state["repositories"]["example/public"]
    public["runs"][0]["actor"] = None
    public["attempts"]["3"]["1"][0]["labels"] = None
    workflows = measurement.aggregate(state)["workflows"]
    result = next(row for row in workflows if row["repo"] == "example/public")
    assert result["unknown_billing_rounded_minutes"] == 4
    assert result["renovate_runs"] == 0


@pytest.mark.parametrize("gap", ["listing", "timing", "attempt"])
def test_incomplete_average_is_null(
    measurement: ModuleType,
    state: dict[str, Any],
    gap: str,
) -> None:
    """Every required coverage dimension must be known before averaging."""
    public = state["repositories"]["example/public"]
    if gap == "listing":
        public["listing_complete"] = False
    elif gap == "timing":
        public["attempts"]["3"]["1"][0]["completed_at"] = None
    else:
        public["runs"][0]["run_attempt"] = 2
    workflows = measurement.aggregate(state)["workflows"]
    workflow = next(row for row in workflows if row["repo"] == "example/public")
    assert workflow["wall_minutes_per_run"] is None


@pytest.mark.parametrize("marker", ["directory", "worktree-file"])
def test_output_refuses_git_checkout_before_writing(
    tmp_path: Path,
    invoke: Callable[..., int],
    marker: str,
) -> None:
    """Both regular checkouts and linked worktrees reject nested private output."""
    if marker == "directory":
        (tmp_path / ".git").mkdir()
    else:
        (tmp_path / ".git").write_text("gitdir: /example/worktrees/test\n")
    with pytest.raises(SystemExit) as error:
        invoke("--offline", "--output", str(tmp_path / "nested" / "private"))
    assert error.value.code == 2
    assert not (tmp_path / "nested").exists()


def test_private_permissions_cover_existing_outputs_and_cache(
    measurement: ModuleType,
    tmp_path: Path,
) -> None:
    """Legacy directories and files are restricted as well as newly written pages."""
    tmp_path.chmod(0o755)
    cache = tmp_path / "cache"
    cache.mkdir(mode=0o755)
    old = cache / "old.json"
    old.write_text('{"endpoint": "/old", "body": {}}')
    old.chmod(0o644)
    group = cache / "existing-endpoint"
    group.mkdir(mode=0o755)
    nested = group / "page.json"
    nested.write_text("{}")
    nested.chmod(0o644)
    checkpoint = tmp_path / "checkpoint.json"
    checkpoint.write_text("{}")
    checkpoint.chmod(0o644)
    measurement.prepare_output(tmp_path)
    assert cache.stat().st_mode & 0o777 == 0o700
    assert old.stat().st_mode & 0o777 == 0o600
    assert group.stat().st_mode & 0o777 == 0o700
    assert nested.stat().st_mode & 0o777 == 0o600
    measurement.API(tmp_path, 30)
    measurement.save(cache / "new.json", {"private": "synthetic"})
    assert tmp_path.stat().st_mode & 0o777 == 0o700
    assert cache.stat().st_mode & 0o777 == 0o700
    for path in (old, checkpoint, cache / "new.json"):
        assert path.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("bound", ["fractional", "future"])
def test_cli_rejects_unstable_window(
    invoke: Callable[..., int],
    tmp_path: Path,
    bound: str,
) -> None:
    """Open snapshots and sub-second input fail before output or network work."""
    end = "2999-01-01T00:00:00Z" if bound == "future" else "2026-10-02T00:00:01.5Z"
    with pytest.raises(SystemExit) as error:
        invoke("--end", end)
    assert error.value.code == 2
    assert not (tmp_path / "checkpoint.json").exists()


def test_fractional_search_cap_cannot_recurse_without_progress(
    measurement: ModuleType,
) -> None:
    """Even internal callers cannot split a 1.5-second range into itself."""

    def capped(_endpoint: str) -> dict[str, Any]:
        return {"total_count": 1000, "workflow_runs": []}

    with pytest.raises(measurement.BudgetExceeded, match="unsplittable"):
        measurement.list_runs(
            SimpleNamespace(get=capped),
            "example/repo",
            measurement.stamp("2026-10-01T00:00:00Z"),
            measurement.stamp("2026-10-01T00:00:01.5Z"),
        )


def test_complete_main_summary_exposes_unknown_billing(
    measurement: ModuleType,
    state: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A complete online collection exits zero and reports uncertainty separately."""
    public = state["repositories"]["example/public"]
    run = {
        **public["runs"][0],
        "status": "completed",
        "created_at": "2026-10-02T00:00:00Z",
    }
    jobs = [{**job, "status": "completed"} for job in public["attempts"]["3"]["1"]]
    monkeypatch.setattr(measurement.API, "get", lambda *_args: {"private": False})
    monkeypatch.setattr(measurement, "list_runs", lambda *_args: [run])
    monkeypatch.setattr(measurement.API, "pages", lambda *_args: jobs)
    assert invoke("--repo", "example/public") == 0
    summary = json.loads(capsys.readouterr().out)
    assert summary["complete"] is True
    assert summary["unknown_time_jobs"] == 0
    assert summary["unknown_billing_rounded_minutes"] == 2


def test_optional_org_failure_continues_explicit_and_checkpointed_repos(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
) -> None:
    """An optional 404 leaves a gap while independent accessible repos are collected."""
    state["repositories"].pop("example/private")
    measurement.save(tmp_path / "checkpoint.json", state)
    calls = []

    def pages(_api: Any, endpoint: str, *_args: Any) -> list[Any]:
        if endpoint.startswith("/orgs/"):
            raise measurement.BudgetExceeded("GET failed: HTTP 404")
        return []

    def list_runs(_api: Any, repo: str, *_args: Any) -> list[Any]:
        calls.append(repo)
        return []

    monkeypatch.setattr(measurement.API, "pages", pages)
    monkeypatch.setattr(measurement.API, "get", lambda *_args: {"private": False})
    monkeypatch.setattr(measurement, "list_runs", list_runs)
    assert invoke("--private-org", "example", "--repo", "example/explicit") == 2
    checkpoint = json.loads((tmp_path / "checkpoint.json").read_text())
    assert sorted(calls) == ["example/explicit", "example/public"]
    assert checkpoint["org_inventory"]["complete"] is False
    assert "404" in checkpoint["collection_error"]
    assert all(repo["listing_complete"] for repo in checkpoint["repositories"].values())


class CheckpointLock:
    """Expose lock ownership so concurrent serialization checks need no timing race."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.owner: int | None = None

    def acquire(self) -> None:
        """Track the thread allowed to mutate the checkpoint."""
        # Acquisition spans the context methods so ownership can be asserted.
        self.lock.acquire()  # pylint: disable=consider-using-with
        self.owner = threading.get_ident()

    def release(self) -> None:
        """Clear ownership before releasing the underlying lock."""
        self.owner = None
        self.lock.release()

    def __enter__(self) -> "CheckpointLock":
        self.acquire()
        return self

    def __exit__(self, *_args: Any) -> None:
        self.release()


def test_concurrent_inventory_mutations_share_serialization_lock(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Four synchronized inventories must mutate and serialize under the same lock."""
    lock = CheckpointLock()
    barrier = threading.Barrier(4)
    main_thread = threading.get_ident()
    original_save = measurement.save

    def assert_owned() -> None:
        if threading.get_ident() != main_thread:
            assert lock.owner == threading.get_ident(), "unlocked checkpoint access"

    class GuardedRepo(dict[str, Any]):
        """Fail deterministically on mutation or serialization outside the lock."""

        def __setitem__(self, key: str, value: Any) -> None:
            assert_owned()
            super().__setitem__(key, value)

        def update(self, *args: Any, **kwargs: Any) -> None:
            assert_owned()
            super().update(*args, **kwargs)

        def pop(self, *args: Any) -> Any:
            assert_owned()
            return super().pop(*args)

        def items(self) -> Any:
            assert_owned()
            return super().items()

    def list_runs(*_args: Any) -> list[Any]:
        barrier.wait(timeout=5)
        assert api.deadline < original_deadline
        return []

    def save(path: Path, value: Any) -> None:
        assert_owned()
        original_save(path, value)

    repos = {f"example/repo-{i}": GuardedRepo(error="old") for i in range(4)}
    state["repositories"] = repos
    api = measurement.API(tmp_path, 30)
    original_deadline = api.deadline
    monkeypatch.setattr(measurement, "threading", SimpleNamespace(Lock=lambda: lock))
    monkeypatch.setattr(measurement, "list_runs", list_runs)
    monkeypatch.setattr(measurement, "save", save)
    measurement.collect(api, state, tmp_path / "checkpoint.json")
    assert api.deadline == original_deadline
    assert all(
        (data["listing_complete"] and "error" not in data for data in repos.values()),
    )
    assert json.loads((tmp_path / "checkpoint.json").read_text()) == state


def test_resume_refreshes_listings_retries_and_unfinished_attempt_pages(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Resumes replace mutable pages, discover retries, and reuse finished attempts."""
    state["repositories"] = {"example/public": {"private": False}}
    phase = [0]
    calls: list[str] = []

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        endpoint = command[-1]
        calls.append(endpoint)
        active = phase[0] == 0
        if "/actions/runs?" in endpoint:
            body = {
                "total_count": 1,
                "workflow_runs": [
                    {
                        "id": 3,
                        "name": "CI",
                        "workflow_id": 6,
                        "event": "push",
                        "head_sha": "abc",
                        "created_at": "2026-10-02T00:00:00Z",
                        "status": "in_progress" if active else "completed",
                        "run_attempt": 1 if active else 2,
                        "actor": {"login": "example", "private_extra": "omit this"},
                    }
                ],
            }
        else:
            assert "/attempts/" in endpoint
            body = {
                "jobs": [
                    {
                        "id": 31,
                        "name": "test",
                        "started_at": "2026-10-02T00:00:00Z",
                        "completed_at": None if active else "2026-10-02T00:01:00Z",
                        "status": "in_progress" if active else "completed",
                        "labels": None,
                    }
                ]
            }
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(body),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    checkpoint = tmp_path / "checkpoint.json"
    for number in range(3):
        phase[0] = number
        api = measurement.API(tmp_path, 30)
        measurement.collect(api, state, checkpoint)
        workflow = measurement.aggregate(state)["workflows"][0]
        if number == 0:
            assert not measurement.coverage_complete(state)
            assert workflow["wall_minutes_per_run"] is None
            assert workflow["unknown_time_jobs"] == 1
            assert state["last_collection"]["stopped"] == "coverage gaps"
            state["repositories"]["example/public"]["jobs_error"] = "stale failure"
            measurement.save(checkpoint, state)
        else:
            assert measurement.coverage_complete(state)
            assert workflow["fetched_attempts"] == 2
            assert workflow["unknown_time_jobs"] == 0
            assert workflow["wall_minutes_per_run"] == 2
            assert "jobs_error" not in state["repositories"]["example/public"]
            assert state["last_collection"]["stopped"] == "finished"
        public = state["repositories"]["example/public"]
        assert public["runs"][0]["actor"] == {"login": "example"}
        # Exercise the actual persisted resume shape, not shared in-memory objects.
        state = json.loads(checkpoint.read_text())
    assert sum("/actions/runs?" in endpoint for endpoint in calls) == 3
    assert sum("/attempts/1/jobs?" in endpoint for endpoint in calls) == 2
    assert sum("/attempts/2/jobs?" in endpoint for endpoint in calls) == 1


@pytest.mark.parametrize("finishes_before_fetch", [False, True])
def test_persisted_resume_requires_terminal_fetch_provenance(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    finishes_before_fetch: bool,
) -> None:
    """Completed observed jobs cannot certify a snapshot of a still-active run."""
    # Pytest injects fixtures alongside the scenario parameter.
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    public = state["repositories"]["example/public"]
    run = {
        **public["runs"][0],
        "created_at": "2026-10-02T00:00:00Z",
        "status": "in_progress",
    }
    first = {**public["attempts"]["3"]["1"][0], "status": "completed"}
    downstream = {**first, "id": 34, "name": "downstream"}
    state["repositories"] = {"example/public": {"private": False}}
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    phase = 0
    job_calls = []

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        endpoint = command[-1]
        if "/actions/runs?" in endpoint:
            listed = {**run, "status": "in_progress" if phase == 0 else "completed"}
            body = {"total_count": 1, "workflow_runs": [listed]}
        else:
            assert "/attempts/1/jobs?" in endpoint
            job_calls.append(phase)
            if phase == 1:
                raise measurement.subprocess.TimeoutExpired(command, 1)
            # The parent can finish after listing but before fetching these jobs.
            finished = phase > 0 or finishes_before_fetch
            batch = [first, downstream] if finished else [first]
            body = {"jobs": batch}
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(body),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    assert invoke() == 2
    stored = json.loads(checkpoint.read_text())
    public = stored["repositories"]["example/public"]
    assert public["terminal_attempts"]["3"]["1"] is False
    workflow = measurement.aggregate(stored)["workflows"][0]
    assert workflow["unknown_time_jobs"] == 0
    assert workflow["wall_minutes_per_run"] is None

    # A terminal listing followed by a failed refresh must retain partial coverage.
    phase = 1
    assert invoke() == 2
    stored = json.loads(checkpoint.read_text())
    assert not measurement.coverage_complete(stored)
    workflow = measurement.aggregate(stored)["workflows"][0]
    assert workflow["complete_runs"] == 0
    assert workflow["wall_minutes_per_run"] is None

    phase = 2
    assert invoke() == 0
    stored = json.loads(checkpoint.read_text())
    public = stored["repositories"]["example/public"]
    assert [job["name"] for job in public["attempts"]["3"]["1"]] == [
        "macos",
        "downstream",
    ]
    assert public["terminal_attempts"]["3"]["1"] is True
    assert measurement.coverage_complete(stored)
    workflow = measurement.aggregate(stored)["workflows"][0]
    assert workflow["wall_minutes_per_run"] == pytest.approx(122 / 60)
    assert invoke() == 0
    assert job_calls == [0, 1, 2]


def test_legacy_checkpoint_refreshes_before_claiming_complete(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
) -> None:
    """Old checkpoints retain measured usage but cannot prove terminal fetches."""
    public = state["repositories"]["example/public"]
    public.pop("terminal_attempts", None)
    public["runs"][0].update(status="completed", created_at="2026-10-02T00:00:00Z")
    state["repositories"] = {"example/public": public}
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    calls = []

    def pages(_api: Any, endpoint: str, field: str) -> list[dict[str, Any]]:
        calls.append((endpoint, field))
        return []  # An explicitly fetched empty terminal attempt is valid too.

    monkeypatch.setattr(measurement.API, "pages", pages)
    assert invoke("--offline") == 2
    workflow = measurement.aggregate(json.loads(checkpoint.read_text()))["workflows"][0]
    assert workflow["wall_minutes_per_run"] is None
    assert workflow["wall_seconds"] == 123
    assert invoke("--jobs-only") == 0
    stored = json.loads(checkpoint.read_text())["repositories"]["example/public"]
    assert stored["terminal_attempts"]["3"]["1"] is True
    assert invoke("--jobs-only") == 0
    assert calls == [("/repos/example/public/actions/runs/3/attempts/1/jobs", "jobs")]


@pytest.mark.parametrize(
    ("payload", "field"),
    [
        ({}, "jobs"),
        (None, "jobs"),
        ([], "workflow_runs"),
        ({"jobs": None}, "jobs"),
        ({"jobs": {}}, "jobs"),
        ({"jobs": [None]}, "jobs"),
        ({"workflow_runs": ["invalid"]}, "workflow_runs"),
        ({"message": "invalid"}, None),
        ([None], None),
    ],
)
def test_malformed_api_lists_fail_closed(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    payload: Any,
    field: str | None,
) -> None:
    """Wrong envelopes, non-lists and non-object members are resumable failures."""
    api = measurement.API(tmp_path, 30)
    monkeypatch.setattr(api, "get", lambda _endpoint: payload)
    with pytest.raises(measurement.BudgetExceeded, match="API page"):
        api.pages("/list", field)


@pytest.mark.parametrize(
    ("private_org", "payload"),
    [
        (True, [{}]),
        (True, [{"private": True}]),
        (False, None),
        (False, {"private": "false"}),
    ],
)
def test_malformed_repository_payloads_remain_incomplete(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    private_org: bool,
    payload: Any,
) -> None:
    """Missing repository fields cannot crash discovery or certify its scope."""
    # Pytest injects fixtures alongside the malformed response parameters.
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    monkeypatch.setattr(measurement.API, "get", lambda *_args: payload)
    monkeypatch.setattr(measurement.API, "pages", lambda *_args: payload)
    flags = ["--private-org", "example"] if private_org else ["--repo", "example/repo"]
    assert invoke(*flags) == 2
    stored = json.loads((tmp_path / "checkpoint.json").read_text())
    assert "invalid API repository" in stored["collection_error"]
    assert stored["repositories"] == {}
    assert stored["last_collection"]["stopped"] == "coverage gaps"


@pytest.mark.parametrize(
    "payload",
    [
        *(
            {"total_count": count, "workflow_runs": []}
            for count in (None, True, False, "1", -1, 1.5, {"bad": 1}, [1])
        ),
        None,
        {},
        [],
        {"total_count": 0},
        {"total_count": 1, "workflow_runs": [{}]},
        {
            "total_count": 1,
            "workflow_runs": [{"id": 1, "created_at": "2026-10-02T00:00:00Z"}],
        },
    ],
)
def test_malformed_run_listing_does_not_crash_recovery(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    payload: Any,
) -> None:
    """Malformed successful responses keep the checkpoint and last-collection record."""
    # Pytest injects fixtures alongside the malformed response parameter.
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    state["repositories"] = {"example/public": {"private": False}}
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)

    def response(*_args: Any, **_kwargs: Any) -> SimpleNamespace:
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(payload),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    assert invoke() == 2
    stored = json.loads(checkpoint.read_text())
    public = stored["repositories"]["example/public"]
    assert not public["listing_complete"]
    assert "invalid API" in public["error"] or "missing API" in public["error"]
    assert stored["last_collection"]["stopped"] == "coverage gaps"


def test_offline_summary_exposes_unknown_time_and_checkpoint_scope(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    invoke: Callable[..., int],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Offline scope describes the checkpoint, independently of inventory flags."""
    measurement.save(tmp_path / "checkpoint.json", state)

    def unexpected(*_args: Any) -> None:
        pytest.fail("offline attempted API work")

    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(measurement.API, "get", unexpected)
        flags = ["--offline", "--repo", "example/ignored", "--private-org", "ignored"]
        assert invoke(*flags) == 2
    summary = json.loads(capsys.readouterr().out)
    assert summary["scope"] == "checkpoint"
    assert summary["unknown_time_jobs"] == 1
    assert summary["unknown_billing_rounded_minutes"] == 2


def test_timeout_retains_bounded_failure(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A subprocess timeout becomes a resumable coverage gap."""

    def timeout(command: list[str], **kwargs: Any) -> None:
        assert 0 < kwargs["timeout"] <= 30
        raise measurement.subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr(measurement.subprocess, "run", timeout)
    with pytest.raises(measurement.BudgetExceeded, match="timed out"):
        measurement.API(tmp_path, 30).get("/timeout")
