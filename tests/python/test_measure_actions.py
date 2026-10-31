# SPDX-License-Identifier: MIT
"""Fixture aggregation and bounded, read-only collection regression tests."""

# pylint: disable=too-many-lines  # Keep the focused CLI regressions together.

import json
import sys
import threading
from collections.abc import Callable
from datetime import datetime, timezone
from itertools import permutations
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
    result["scope"] = {"repos": [], "private_org": None}
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
    "labels,kind,multiplier",
    [
        (["ubuntu-latest", "custom-large"], "unknown", None),
        (["ubuntu-latest", "windows-latest"], "unknown", None),
        (["windows-2025", "macos-15"], "unknown", None),
        (["ubuntu-latest", "ubuntu-latest-16-cores"], "unknown", None),
        (["ubuntu-latest", "blacksmith-4vcpu-ubuntu-2404"], "unknown", None),
        (["blacksmith-4vcpu-ubuntu-2404"], "unknown", None),
        (["ubuntu-latest", "Linux", "X64"], "unknown", None),
        (["self-hosted", "ubuntu-latest", "custom-large"], "self-hosted", None),
        (["self-hosted", "blacksmith-4vcpu-ubuntu-2404"], "self-hosted", None),
        (["ubuntu-latest", "ubuntu-24.04"], "linux", 1),
        (["windows-latest", "windows-2025"], "windows", 2),
        (["macos-latest", "macos-15"], "macos", 10),
    ],
)
def test_runner_evidence_is_order_independent(
    measurement: ModuleType,
    labels: list[str],
    kind: str,
    multiplier: int | None,
) -> None:
    """All evidence must support one hosted OS; explicit self-hosted stays separate."""
    for order in permutations(labels):
        job = {
            "labels": list(order),
            "started_at": "2026-10-02T00:00:00Z",
            "completed_at": "2026-10-02T00:01:01Z",
        }
        assert measurement.runner_kind(job) == (kind, multiplier)
        for private in (True, False, None):
            metrics = measurement.job_metrics(
                job, private, measurement.stamp("2026-10-31T00:00:00Z")
            )
            assert metrics["rounded_job_minutes"] == 2
            if kind == "unknown":
                assert metrics["unknown_billing_rounded_minutes"] == 2
                assert metrics["estimated_private_plan_minutes"] == 0
                assert metrics["public_free_rounded_minutes"] == 0
            elif kind == "self-hosted":
                assert metrics["self_hosted_rounded_minutes"] == 2
                assert metrics["unknown_billing_rounded_minutes"] == 0


@pytest.mark.parametrize(
    "labels,expected",
    [
        (
            [
                "ubuntu-latest",
                "ubuntu-22.04",
                "ubuntu-24.04",
                "ubuntu-26.04",
                "ubuntu-22.04-arm",
                "ubuntu-24.04-arm",
                "ubuntu-26.04-arm",
            ],
            ("linux", 1),
        ),
        (["windows-latest", "windows-2022", "windows-2025"], ("windows", 2)),
        (
            [
                "macos-latest",
                "macos-13",
                "macos-14",
                "macos-15",
                "macos-15-intel",
                "macos-26",
            ],
            ("macos", 10),
        ),
    ],
)
def test_supported_hosted_labels(
    measurement: ModuleType, labels: list[str], expected: tuple[str, int]
) -> None:
    """Known standard images, including ARM and Intel, retain their OS multiplier."""
    for label in labels:
        assert measurement.runner_kind({"labels": [label.upper()]}) == expected


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


def test_run_snapshot_observation_time_survives_cache_replay(
    measurement: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Replaying an old page must not give its rows a new observation timestamp."""
    observed = datetime(2026, 10, 2, tzinfo=timezone.utc)
    clock = SimpleNamespace(now=lambda _tz: observed)
    calls = []

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        calls.append(command[-1])
        return SimpleNamespace(
            returncode=0,
            stdout='HTTP/2.0 200 OK\n\n{"workflow_runs": [{"id": 1}]}',
        )

    monkeypatch.setattr(measurement, "datetime", clock)
    monkeypatch.setattr(measurement.subprocess, "run", response)
    endpoint = "/repos/example/repo/actions/runs?per_page=100&page=1"
    first = measurement.API(tmp_path, 30).get(endpoint)
    assert first["workflow_runs"][0]["_observed_at"] == observed.isoformat()
    observed = datetime(2026, 10, 3, tzinfo=timezone.utc)
    api = measurement.API(tmp_path, 30)
    assert api.get(endpoint) == first
    assert calls == [endpoint]
    api.invalidate(endpoint)
    refreshed = api.get(endpoint)
    assert refreshed["workflow_runs"][0]["_observed_at"] == observed.isoformat()
    assert refreshed != first
    assert calls == [endpoint, endpoint]


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


def test_run_listing_deduplicates_attempts_and_snapshots_monotonically(
    measurement: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Overlapping listing pages cannot hide retries or revive stale terminal rows."""
    api = measurement.API(tmp_path, 30)
    base = {"id": 1, "created_at": "2026-10-02T00:00:00Z", "run_attempt": 2}
    newest = {**base, "status": "in_progress", "updated_at": "2026-10-02T00:02:00Z"}
    rows = [
        newest,
        {**base, "status": "completed", "updated_at": "2026-10-02T00:01:00Z"},
        {**newest, "run_attempt": 1, "updated_at": "2026-10-02T00:03:00Z"},
    ]
    monkeypatch.setattr(
        api,
        "get",
        lambda _endpoint: {"total_count": 3, "workflow_runs": []},
    )
    for order in permutations(rows):
        monkeypatch.setattr(api, "pages", lambda *_args, order=order: list(order))
        assert measurement.list_runs(
            api,
            "example/repo",
            measurement.stamp(base["created_at"]),
            measurement.stamp("2026-10-31T00:00:00Z"),
        ) == [newest]


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


@pytest.mark.parametrize("listing_finishes", [False, True])
def test_inventory_preserves_newer_checkpoint_attempts_and_retry_totals(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    listing_finishes: bool,
) -> None:
    """Even a fresher attempt-1 page cannot erase checkpointed attempt-2 usage."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    private = state["repositories"]["example/private"]
    run = {
        **private["runs"][0],
        "created_at": "2026-10-02T00:00:00Z",
        "updated_at": "2026-10-02T00:02:00Z",
    }
    private["runs"] = [run]
    private["attempts"]["1"]["2"] = private["attempts"]["1"]["2"][:1]
    state["repositories"] = {"example/private": private}
    before = measurement.aggregate(state)["workflows"][0]
    older = {**run, "run_attempt": 1, "updated_at": "2026-10-02T00:03:00Z"}

    def listing(api: Any, *_args: Any) -> list[dict[str, Any]]:
        if listing_finishes:
            return [older]
        group = api.cache_group("/repos/example/private/actions/runs")
        group.mkdir(exist_ok=True)
        measurement.save(group / "page.json", {"body": {"workflow_runs": [older]}})
        raise measurement.BudgetExceeded("interrupted listing")

    def unexpected(*_args: Any, **_kwargs: Any) -> None:
        pytest.fail("immutable checkpoint attempts must be reused")

    monkeypatch.setattr(measurement, "list_runs", listing)
    monkeypatch.setattr(measurement.subprocess, "run", unexpected)
    checkpoint = tmp_path / "checkpoint.json"
    measurement.collect(measurement.API(tmp_path, 30), state, checkpoint)
    stored = json.loads(checkpoint.read_text())
    assert stored["repositories"]["example/private"]["runs"][0]["run_attempt"] == 2
    result = measurement.aggregate(stored)
    workflow = result["workflows"][0]
    assert workflow["expected_attempts"] == workflow["fetched_attempts"] == 2
    for metric in measurement.empty_metrics():
        assert workflow[metric] == before[metric]
        partitioned = workflow["first"][metric] + workflow["retries"][metric]
        assert workflow[metric] == partitioned
        assert workflow[metric] == sum(job[metric] for job in result["jobs"])
    assert workflow["retries"]["wall_seconds"] == 60
    assert measurement.coverage_complete(stored) is listing_finishes


@pytest.mark.parametrize(
    "freshness,status",
    [
        ("updated_at", "in_progress"),
        ("updated_at", "completed"),
        ("api_priority", "in_progress"),
        ("offset", "in_progress"),
        ("_observed_at", "in_progress"),
        ("_observed_at", "completed"),
        ("missing", "in_progress"),
        ("invalid", "in_progress"),
        ("tied", "in_progress"),
    ],
)
def test_recovery_uses_freshness_and_conservative_status_independent_of_page_order(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    freshness: str,
    status: str,
) -> None:
    """Stale terminal rows cannot win over newer or equally fresh active evidence."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    api = measurement.API(tmp_path, 30)
    group = api.cache_group("/repos/example/repo/actions/runs")
    group.mkdir()
    base = {"id": 1, "created_at": "2026-10-02T00:00:00Z", "run_attempt": 2}
    rows = [
        {**base, "status": "completed", "name": "old"},
        {**base, "status": "in_progress", "name": "active"},
        {**base, "status": status, "name": "new"},
    ]
    for index, row in enumerate(rows):
        if freshness in ("updated_at", "_observed_at"):
            row[freshness] = f"2026-10-02T00:0{index}:00Z"
        elif freshness == "api_priority":
            row["updated_at"] = f"2026-10-02T00:0{index}:00Z"
            row["_observed_at"] = f"2026-10-03T00:0{2 - index}:00Z"
        elif freshness == "offset":
            row["updated_at"] = f"2026-10-02T00:0{index}:00Z"
            if index == 2:
                row["updated_at"] = "2026-10-01T21:02:00-03:00"
        elif freshness == "invalid":
            row["updated_at"] = "invalid"
        elif freshness == "tied":
            row["updated_at"] = "2026-10-02T00:00:00Z"
        measurement.save(group / f"{index}.json", {"body": {"workflow_runs": [row]}})
    paths = list(group.glob("*.json"))
    selected = []
    for order in permutations(paths):
        with monkeypatch.context() as patch:
            patch.setattr(Path, "glob", lambda *_args, order=order: iter(order))
            recovered = measurement.recover_runs(
                api,
                "example/repo",
                measurement.stamp(base["created_at"]),
                measurement.stamp("2026-10-31T00:00:00Z"),
            )
        assert len(recovered) == 1
        assert recovered[0]["status"] == status
        selected.append(recovered[0])
        if freshness in ("updated_at", "_observed_at", "api_priority", "offset"):
            assert recovered[0] == rows[-1]
    assert all(row == selected[0] for row in selected)


@pytest.mark.parametrize("checkpoint_is_newer", [False, True])
def test_interrupted_inventory_retains_fresh_active_snapshot_without_terminal_coverage(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    checkpoint_is_newer: bool,
) -> None:
    """A stale completed listing must not certify partial jobs as terminal."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    public = state["repositories"]["example/public"]
    run = {**public["runs"][0], "created_at": "2026-10-02T00:00:00Z"}
    active = {**run, "status": "in_progress", "updated_at": "2026-10-02T00:02:00Z"}
    terminal = {**run, "status": "completed", "updated_at": "2026-10-02T00:01:00Z"}
    public["runs"] = [active if checkpoint_is_newer else terminal]
    public["terminal_attempts"] = {}
    state["repositories"] = {"example/public": public}
    jobs: list[dict[str, Any]] = public["attempts"]["3"]["1"]

    def listing(api: Any, *_args: Any) -> None:
        group = api.cache_group("/repos/example/public/actions/runs")
        group.mkdir(exist_ok=True)
        row = terminal if checkpoint_is_newer else active
        measurement.save(group / "page.json", {"body": {"workflow_runs": [row]}})
        raise measurement.BudgetExceeded("interrupted listing")

    def pages(_endpoint: str, field: str) -> list[dict[str, Any]]:
        assert field == "jobs"
        return jobs

    monkeypatch.setattr(measurement, "list_runs", listing)
    api = measurement.API(tmp_path, 30)
    monkeypatch.setattr(api, "pages", pages)
    checkpoint = tmp_path / "checkpoint.json"
    measurement.collect(api, state, checkpoint)
    stored = json.loads(checkpoint.read_text())
    public = stored["repositories"]["example/public"]
    assert public["runs"][0]["status"] == "in_progress"
    assert public["runs"][0]["updated_at"] == active["updated_at"]
    assert public["terminal_attempts"]["3"]["1"] is False
    workflow = measurement.aggregate(stored)["workflows"][0]
    assert workflow["complete_runs"] == 0
    assert workflow["wall_minutes_per_run"] is None
    assert not measurement.coverage_complete(stored)


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
    state["scope"] = {"repos": [], "private_org": "example"}
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


@pytest.mark.parametrize("reason", ["403", "429", "quota", "deadline"])
def test_pacing_rechecks_stop_and_deadline_before_admission(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    reason: str,
) -> None:
    """Publish a response's stop while another worker is held in pacing."""
    # pylint: disable=too-many-locals  # Events enforce ordering, never timing.
    first_started = threading.Event()
    pacing = threading.Event()
    first_finished = threading.Event()
    now = 0.0
    calls = []
    outcomes: dict[str, Any] = {}

    def pause(delay: float) -> None:
        nonlocal now
        if delay:
            assert delay == 0.25
            pacing.set()
            assert first_finished.wait(timeout=5), "stop publication blocked by pacing"
            now = api.deadline + 1 if reason == "deadline" else now + delay

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        endpoint = command[-1]
        calls.append(endpoint)
        if endpoint == "/first":
            first_started.set()
            assert pacing.wait(timeout=5), "second worker never reached pacing"
        if reason in {"403", "429"}:
            return SimpleNamespace(
                returncode=1,
                stdout=f"HTTP/2.0 {reason} Denied\n\n{{}}",
            )
        quota = 99 if reason == "quota" else 5000
        return SimpleNamespace(
            returncode=0,
            stdout=f"HTTP/2.0 200 OK\nX-RateLimit-Remaining: {quota}\n\n{{}}",
        )

    def request(endpoint: str) -> None:
        try:
            outcomes[endpoint] = api.get(endpoint)
        except (measurement.BudgetExceeded, AssertionError) as error:
            outcomes[endpoint] = error
        finally:
            if endpoint == "/first":
                first_finished.set()

    monkeypatch.setattr(
        measurement,
        "time",
        SimpleNamespace(monotonic=lambda: now, sleep=pause),
    )
    monkeypatch.setattr(measurement.subprocess, "run", response)
    api = measurement.API(tmp_path, 30)
    first = threading.Thread(target=request, args=("/first",), daemon=True)
    second = threading.Thread(target=request, args=("/queued",), daemon=True)
    first.start()
    assert first_started.wait(timeout=5)
    second.start()
    first.join(timeout=10)
    second.join(timeout=10)
    assert not first.is_alive() and not second.is_alive()
    assert calls == ["/first"], "queued request launched after stop/deadline"
    assert api.requests == 1
    if reason in {"403", "429"}:
        assert "GET failed" in str(outcomes["/first"])
    else:
        assert outcomes["/first"] == {}
    assert isinstance(outcomes["/queued"], measurement.BudgetExceeded)
    expected = "budget" if reason == "deadline" else reason
    assert expected in str(outcomes["/queued"])


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
    state["scope"] = {"repos": ["example/explicit"], "private_org": "example"}
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


@pytest.mark.parametrize(
    "defect",
    [
        "org-envelope",
        "org-row",
        "runs-count",
        "runs-envelope",
        "runs-row",
        "jobs-envelope",
    ],
)
def test_normal_resume_recovers_from_malformed_cached_page(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    defect: str,
) -> None:
    """A corrected response replaces bad cached data through a persisted resume."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    public = state["repositories"]["example/public"]
    run = {**public["runs"][0], "created_at": "2026-10-02T00:00:00Z"}
    job = {**public["attempts"]["3"]["1"][0], "status": "completed"}
    organization = defect.startswith("org-")
    state["repositories"] = {"example/public": {"private": False}}
    if organization:
        state["repositories"] = {}
    state["scope"] = {"repos": [], "private_org": "example" if organization else None}
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    corrected = False
    requested = []

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        endpoint = command[-1]
        kind = "org" if endpoint.startswith("/orgs/") else "runs"
        if "/jobs?" in endpoint:
            kind = "jobs"
        page = int(endpoint.rsplit("page=", 1)[1])
        target = defect.startswith(f"{kind}-")
        if target:
            requested.append(page)
        size = 100 if target and page == 1 and defect != "runs-count" else 1
        if kind == "org":
            body: Any = [{"full_name": "example/public", "private": True}] * size
        elif kind == "runs":
            count = 101 if target and defect != "runs-count" else 1
            body = {"total_count": count, "workflow_runs": [run] * size}
        else:
            body = {"jobs": [job] * size}
        bad_page = 1 if defect == "runs-count" else 2
        if target and not corrected and page == bad_page:
            body = {
                "org-envelope": {},
                "org-row": [{"private": True}],
                "runs-count": {"total_count": "1", "workflow_runs": [run]},
                "runs-envelope": {"total_count": 101, "workflow_runs": None},
                "runs-row": {"total_count": 101, "workflow_runs": [{}]},
                "jobs-envelope": {"jobs": [None]},
            }[defect]
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(body),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    flags = ["--private-org", "example"] if organization else []
    assert invoke(*flags) == 2
    interrupted = json.loads(checkpoint.read_text())
    if organization:
        assert not interrupted["org_inventory"]["complete"]
        assert not interrupted["repositories"]
    elif defect.startswith("runs-"):
        assert not interrupted["repositories"]["example/public"]["listing_complete"]
    else:
        attempts = interrupted["repositories"]["example/public"]["terminal_attempts"]
        assert not attempts["3"]
    corrected = True
    assert invoke(*flags) == 0
    assert measurement.coverage_complete(json.loads(checkpoint.read_text()))
    # Semantic checks rebuild an aggregate cursor; envelope checks keep page 1.
    expected = [1, 2, 1, 2] if defect.endswith("row") else [1, 2, 2]
    assert requested == ([1, 1] if defect == "runs-count" else expected)


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


@pytest.mark.parametrize("kind", ["runs", "jobs"])
def test_persisted_pagination_finishes_with_one_page_per_invocation(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    kind: str,
) -> None:
    """A three-page pass finishes across restarts without repeating network work."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    public = state["repositories"]["example/public"]
    run = {
        **public["runs"][0],
        "created_at": "2026-10-02T00:00:00Z",
        "status": "completed",
    }
    job = {
        **public["attempts"]["3"]["1"][0],
        "status": "completed",
        "labels": ["ubuntu-latest"],
        "started_at": "2026-10-02T00:00:00Z",
        "completed_at": "2026-10-02T00:01:00Z",
    }
    state["repositories"] = {"example/public": {"private": False}}
    if kind == "jobs":
        state["repositories"]["example/public"].update(
            runs=[run],
            listing_complete=True,
        )
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    pages: list[int] = []
    allowance = 0

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        nonlocal allowance
        endpoint = command[-1]
        page = int(endpoint.rsplit("page=", 1)[1])
        paginated = ("/actions/runs?" in endpoint) == (kind == "runs")
        if paginated:
            if allowance == 0:
                raise measurement.BudgetExceeded("deterministic page budget")
            allowance -= 1
            pages.append(page)
        size = (100 if page < 3 else 1) if paginated else 1
        template = run if kind == "runs" else job
        rows = [{**template, "id": (page - 1) * 100 + i} for i in range(size)]
        body = (
            {"total_count": 201, "workflow_runs": rows}
            if "/actions/runs?" in endpoint
            else {"jobs": rows if kind == "jobs" else [job]}
        )
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(body),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    for invocation in range(3):
        allowance = 1
        state = json.loads(checkpoint.read_text())
        measurement.collect(
            measurement.API(tmp_path, 30), state, checkpoint, jobs_only=kind == "jobs"
        )
        stored = json.loads(checkpoint.read_text())
        assert measurement.coverage_complete(stored) is (invocation == 2)
        if invocation < 2:
            assert all(
                row["wall_minutes_per_run"] is None
                for row in measurement.aggregate(stored)["workflows"]
            )
    assert pages == [1, 2, 3]
    workflow = measurement.aggregate(stored)["workflows"][0]
    assert workflow["runs"] == (201 if kind == "runs" else 1)
    assert workflow["jobs"] == 201
    assert workflow["rounded_job_minutes"] == 201
    assert workflow["wall_seconds"] == 201 * 60
    if kind == "runs":
        # A completed pass must not hide subsequent retries in cached run pages.
        run["run_attempt"] = 2
        allowance = 3
        state = json.loads(checkpoint.read_text())
        measurement.collect(measurement.API(tmp_path, 30), state, checkpoint)
        assert measurement.coverage_complete(state)
        assert pages == [1, 2, 3, 1, 2, 3]
        workflow = measurement.aggregate(state)["workflows"][0]
        assert workflow["fetched_attempts"] == 402
        assert workflow["rounded_job_minutes"] == 402


@pytest.mark.parametrize("organization", [False, True])
@pytest.mark.parametrize("initial_private", [False, True])
def test_normal_resume_refreshes_visibility_and_classification(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    organization: bool,
    initial_private: bool,
) -> None:
    """Metadata caches cannot pin either direction of a visibility transition."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    public = state["repositories"]["example/public"]
    run = {**public["runs"][0], "created_at": "2026-10-02T00:00:00Z"}
    job = {
        **public["attempts"]["3"]["1"][0],
        "labels": ["ubuntu-latest"],
        "status": "completed",
    }
    private = initial_private
    metadata_calls = []

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        endpoint = command[-1]
        if "/actions/runs?" in endpoint:
            body: Any = {"total_count": 1, "workflow_runs": [run]}
        elif "/jobs?" in endpoint:
            body = {"jobs": [job]}
        else:
            metadata_calls.append(private)
            info = {"private": private, "full_name": "example/public"}
            body = [info] if organization else info
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(body),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    flags = ["--repo", "example/public"]
    if organization:
        # Org-only resumes must also reclassify an already checkpointed public repo.
        state["repositories"] = {"example/public": {"private": not initial_private}}
        state["scope"] = {"repos": [], "private_org": "example"}
        measurement.save(tmp_path / "checkpoint.json", state)
        flags = ["--private-org", "example"]
    for phase in range(2):
        private = initial_private if phase == 0 else not initial_private
        assert invoke(*flags) == 0
        stored = json.loads((tmp_path / "checkpoint.json").read_text())
        assert stored["repositories"]["example/public"]["private"] is private
        workflow = measurement.aggregate(stored)["workflows"][0]
        assert workflow["estimated_private_plan_minutes"] == (2 if private else 0)
        assert workflow["public_free_rounded_minutes"] == (0 if private else 2)
    assert metadata_calls == [initial_private, not initial_private]


def test_normal_resume_validates_normalized_scope_before_api_work(
    measurement: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
) -> None:
    """Equivalent selections resume; repo and organization changes cannot mix data."""
    calls = []

    def get(_api: Any, endpoint: str) -> dict[str, Any]:
        calls.append(endpoint)
        return {"private": False}

    monkeypatch.setattr(measurement.API, "get", get)
    monkeypatch.setattr(measurement.API, "pages", lambda *_args: [])
    monkeypatch.setattr(measurement, "list_runs", lambda *_args: [])
    first = ["--repo", "Example/B", "--repo", "example/a", "--private-org", "Example"]
    assert invoke(*first) == 0
    equivalent = ["--repo", "example/a", "--repo", "example/b", "--repo", "example/a"]
    assert invoke(*equivalent, "--private-org", "example") == 0
    checkpoint = tmp_path / "checkpoint.json"
    before = checkpoint.read_bytes()
    count = len(calls)
    for flags in (
        ["--repo", "example/c", "--private-org", "example"],
        [*equivalent, "--private-org", "other"],
        [],
    ):
        with pytest.raises(SystemExit) as error:
            invoke(*flags)
        assert error.value.code == 2
        assert checkpoint.read_bytes() == before
    assert len(calls) == count
    assert json.loads(before)["scope"] == {
        "repos": ["example/a", "example/b"],
        "private_org": "example",
    }


@pytest.mark.parametrize("mode", ["--offline", "--jobs-only"])
@pytest.mark.parametrize("legacy", [False, True])
def test_checkpoint_modes_ignore_inventory_flags_without_discovery(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    capsys: pytest.CaptureFixture[str],
    mode: str,
    legacy: bool,
) -> None:
    """Offline and jobs-only never add repositories or refresh their metadata."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    state["repositories"].pop("example/private")
    public = state["repositories"]["example/public"]
    public["runs"][0]["created_at"] = "2026-10-02T00:00:00Z"
    if legacy:
        state.pop("scope")
    measurement.save(tmp_path / "checkpoint.json", state)
    before = json.loads(json.dumps(state))

    def unexpected(*_args: Any) -> None:
        pytest.fail("checkpoint mode attempted discovery")

    monkeypatch.setattr(measurement.API, "get", unexpected)
    assert invoke(mode, "--repo", "example/ignored", "--private-org", "ignored") == 0
    stored = json.loads((tmp_path / "checkpoint.json").read_text())
    assert stored["repositories"] == before["repositories"]
    assert stored.get("scope") == before.get("scope")
    assert json.loads(capsys.readouterr().out)["scope"] == "checkpoint"


def test_interrupted_mutable_jobs_restart_once_before_terminal_progress(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Terminal pagination discards early mutable pages and then survives restarts."""
    # pylint: disable=too-many-locals
    public = state["repositories"]["example/public"]
    run = {**public["runs"][0], "created_at": "2026-10-02T00:00:00Z"}
    job = {
        **public["attempts"]["3"]["1"][0],
        "status": "completed",
        "labels": ["ubuntu-latest"],
        "started_at": "2026-10-02T00:00:00Z",
    }
    state["repositories"] = {"example/public": {"private": False}}
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    phase = 0
    allowance = 0
    pages = []

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        nonlocal allowance
        endpoint = command[-1]
        if "/actions/runs?" in endpoint:
            row = {**run, "status": "in_progress" if phase == 0 else "completed"}
            body = {"total_count": 1, "workflow_runs": [row]}
        else:
            if allowance == 0:
                raise measurement.BudgetExceeded("one job page per invocation")
            allowance -= 1
            page = int(endpoint.rsplit("page=", 1)[1])
            pages.append(page)
            batch = [
                {
                    **job,
                    "id": (page - 1) * 100 + i,
                    "completed_at": f"2026-10-02T00:0{1 if phase == 0 else 2}:00Z",
                }
                for i in range(100 if page < 3 else 1)
            ]
            body = {"jobs": batch}
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(body),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    for phase in range(4):
        allowance = 1
        state = json.loads(checkpoint.read_text())
        measurement.collect(measurement.API(tmp_path, 30), state, checkpoint)
        assert measurement.coverage_complete(state) is (phase == 3)
        if phase == 0:
            progress = state["repositories"]["example/public"]["attempt_progress"]
            assert progress["3"]["1"] is False
    assert pages == [1, 1, 2, 3]
    workflow = measurement.aggregate(state)["workflows"][0]
    assert workflow["jobs"] == 201
    assert workflow["wall_seconds"] == 201 * 120
    assert workflow["rounded_job_minutes"] == 402


@pytest.mark.parametrize("refresh", [False, True])
def test_org_discovery_resumes_pages_until_complete_then_refreshes(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    refresh: bool,
) -> None:
    """One org page per invocation eventually finishes a fresh or refresh pass."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    state["repositories"] = {}
    state["scope"] = {"repos": [], "private_org": "example"}
    if refresh:
        state["org_inventory"] = {"org": "example", "complete": True}
        api = measurement.API(tmp_path, 30)
        monkeypatch.setattr(api, "get", lambda _endpoint: [])
        assert api.pages("/orgs/example/repos?type=all") == []
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    pages = []
    allowance = 0

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        nonlocal allowance
        endpoint = command[-1]
        assert endpoint.startswith("/orgs/example/repos?")
        if allowance == 0:
            raise measurement.BudgetExceeded("deterministic page budget")
        allowance -= 1
        page = int(endpoint.rsplit("page=", 1)[1])
        pages.append(page)
        size = 100 if page < 3 else 1
        rows = [
            {
                "full_name": f"example/repo-{page}-{i}",
                "private": page == 3,
            }
            for i in range(size)
        ]
        return SimpleNamespace(
            returncode=0,
            stdout="HTTP/2.0 200 OK\n\n" + json.dumps(rows),
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    monkeypatch.setattr(measurement, "list_runs", lambda *_args: [])
    for invocation in range(3):
        allowance = 1
        assert invoke("--private-org", "example") == (0 if invocation == 2 else 2)
        stored = json.loads(checkpoint.read_text())
        assert stored["org_inventory"]["complete"] is (invocation == 2)
    assert pages == [1, 2, 3]
    assert stored["org_inventory"]["visible_repositories"] == 201
    assert stored["org_inventory"]["private_repositories"] == 1
    allowance = 1
    assert invoke("--private-org", "example") == 2
    assert pages == [1, 2, 3, 1]
    assert invoke("--offline") == 2


@pytest.mark.parametrize("initial_private", [False, True])
@pytest.mark.parametrize("resolution", ["reappears", "explicit"])
@pytest.mark.parametrize("legacy", [False, True])
def test_missing_org_repository_loses_trusted_metadata_until_resolved(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    initial_private: bool,
    resolution: str,
    legacy: bool,
) -> None:
    """Checkpoint modes cannot certify a missing repo or bill stale visibility."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
    # pylint: disable=too-many-statements  # Cover disappearance, resume and recovery.
    public = state["repositories"]["example/public"]
    public["private"] = initial_private
    run = public["runs"][0]
    run["created_at"] = "2026-10-02T00:00:00Z"
    public["attempts"]["3"]["1"] = [
        {**public["attempts"]["3"]["1"][0], "labels": ["ubuntu-latest"]}
    ]
    state["repositories"] = {"example/public": public}
    explicit = ["example/public"] if resolution == "explicit" else []
    state["scope"] = {"repos": explicit, "private_org": "example"}
    # No membership fields: an existing pre-upgrade org checkpoint must reconcile too.
    state["org_inventory"] = {"org": "example", "complete": True}
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    visible = True
    metadata_allowed = False

    def pages(_api: Any, endpoint: str, *_args: Any) -> list[dict[str, Any]]:
        assert endpoint.startswith("/orgs/example/repos?")
        if not visible:
            return []
        return [{"full_name": "example/public", "private": initial_private}]

    def get(_api: Any, endpoint: str) -> dict[str, Any]:
        assert endpoint == "/repos/example/public"
        if not metadata_allowed:
            raise measurement.BudgetExceeded("repository no longer accessible")
        return {"private": not initial_private}

    monkeypatch.setattr(measurement.API, "pages", pages)
    monkeypatch.setattr(measurement.API, "get", get)
    monkeypatch.setattr(measurement, "list_runs", lambda *_args: [run])
    flags = ["--private-org", "example"]
    if explicit:
        flags.extend(["--repo", "example/public"])
    if not legacy:
        assert invoke(*flags) == 0
        observed = json.loads(checkpoint.read_text())["repositories"]["example/public"]
        assert observed["metadata_source"] == "/orgs/example/repos"
        assert observed["inventory_org"] == "example"
    visible = False
    assert invoke(*flags) == 2
    stored = json.loads(checkpoint.read_text())
    missing = stored["repositories"]["example/public"]
    assert stored["org_inventory"]["complete"] is True
    assert missing["inventory_missing"] is True
    assert missing["private"] is None
    assert "metadata_source" not in missing
    assert missing["attempts"] == public["attempts"]
    assert not measurement.coverage_complete(stored)
    # Restored visibility and completed listings/attempts cannot hide the gap.
    missing["private"] = initial_private
    assert not measurement.coverage_complete(stored)
    for mode in ("--offline", "--jobs-only"):
        assert invoke(mode) == 2
        result = json.loads((tmp_path / "measurements.json").read_text())
        workflow = result["workflows"][0]
        assert workflow["private"] is None
        assert workflow["estimated_private_plan_minutes"] == 0
        assert workflow["public_free_rounded_minutes"] == 0
        assert workflow["unknown_billing_rounded_minutes"] == 2
    visible = resolution == "reappears"
    metadata_allowed = True
    assert invoke(*flags) == 0
    resolved = json.loads(checkpoint.read_text())["repositories"]["example/public"]
    assert not resolved.get("inventory_missing")
    assert resolved["private"] is (initial_private if visible else not initial_private)
    assert resolved["metadata_source"] == (
        "/orgs/example/repos" if visible else "/repos/example/public"
    )
    assert invoke("--offline") == 0


@pytest.mark.parametrize("completed", [0, 4, 9])
def test_unfinished_listings_finish_before_completed_refreshes_with_low_budget(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    completed: int,
) -> None:
    """Nine repos finish across two-request invocations without restarting."""
    state["repositories"] = {
        f"example/repo-{i}": {
            "private": False,
            "listing_complete": i < completed,
            "listing_in_progress": False,
        }
        for i in range(9)
    }
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    allowance = 0
    calls: list[str] = []
    request_lock = threading.Lock()

    def response(command: list[str], **_kwargs: Any) -> SimpleNamespace:
        nonlocal allowance
        with request_lock:
            if allowance == 0:
                raise measurement.BudgetExceeded("deterministic request budget")
            allowance -= 1
            calls.append(command[-1].split("/actions/", 1)[0])
        return SimpleNamespace(
            returncode=0,
            stdout='HTTP/2.0 200 OK\n\n{"total_count": 0, "workflow_runs": []}',
        )

    monkeypatch.setattr(measurement.subprocess, "run", response)
    monkeypatch.setattr(measurement.time, "sleep", lambda _delay: None)
    pending = 9 - completed if completed < 9 else 9
    invocations = (pending + 1) // 2
    for invocation in range(invocations):
        allowance = 2
        stored = json.loads(checkpoint.read_text())
        measurement.collect(measurement.API(tmp_path, 30), stored, checkpoint)
        assert measurement.coverage_complete(stored) is (invocation == invocations - 1)
        assert all(
            stored["repositories"][route.removeprefix("/repos/")]["listing_complete"]
            for route in calls
        )
    expected = range(completed, 9) if completed < 9 else range(9)
    assert sorted(calls) == [f"/repos/example/repo-{i}" for i in expected]


@pytest.mark.parametrize("legacy_org", [None, "example"])
@pytest.mark.parametrize("exact_repos", [False, True])
def test_legacy_scope_adoption_is_bounded_to_unambiguous_explicit_inventory(
    measurement: ModuleType,
    state: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invoke: Callable[..., int],
    legacy_org: str | None,
    exact_repos: bool,
) -> None:
    """Unknown org selections or unmatched legacy inventories require new output."""
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    state.pop("scope")
    state["repositories"] = {"example/public": {"private": False}}
    if legacy_org:
        state["org_inventory"] = {"org": legacy_org, "complete": True}
    checkpoint = tmp_path / "checkpoint.json"
    measurement.save(checkpoint, state)
    before = checkpoint.read_bytes()
    flags = ["--repo", "example/public" if exact_repos else "example/other"]
    if legacy_org:
        flags += ["--private-org", legacy_org]
    if legacy_org or not exact_repos:
        with pytest.raises(SystemExit, match="2"):
            invoke(*flags)
        assert checkpoint.read_bytes() == before
    else:
        monkeypatch.setattr(measurement.API, "get", lambda *_args: {"private": False})
        monkeypatch.setattr(measurement, "list_runs", lambda *_args: [])
        assert invoke(*flags) == 0
        assert json.loads(checkpoint.read_text())["scope"] == {
            "repos": ["example/public"],
            "private_org": None,
        }
