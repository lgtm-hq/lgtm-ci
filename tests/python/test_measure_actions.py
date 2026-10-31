# SPDX-License-Identifier: MIT
"""Fixture aggregation and bounded, read-only collection regression tests."""

import json
import sys
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
    result: dict[str, Any] = json.loads(
        (fixtures_dir / "actions/measurement.json").read_text()
    )
    return result


def test_rounding_attempts_and_missing_coverage(
    measurement: ModuleType, state: dict[str, Any]
) -> None:
    """Round per job before multiplying; missing attempts are never zero usage."""
    result = measurement.aggregate(state)
    private = next(
        row for row in result["workflows"] if row["repo"] == "example/private"
    )
    assert private["wall_seconds"] == 122
    assert private["rounded_job_minutes"] == 4
    assert private["estimated_private_plan_minutes"] == 14
    assert private["first"]["estimated_private_plan_minutes"] == 4
    assert private["retries"]["estimated_private_plan_minutes"] == 10
    assert private["expected_attempts"] == 3
    assert private["fetched_attempts"] == 2
    assert private["complete_runs"] == 1
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
    public = next(
        row
        for row in measurement.aggregate(state)["workflows"]
        if row["repo"] == "example/public"
    )
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
    measurement: ModuleType, change: dict[str, Any]
) -> None:
    """Incomplete, inverted and post-snapshot intervals are explicit unknowns."""
    job = {
        "started_at": "2026-10-02T00:00:00Z",
        "completed_at": "2026-10-02T00:01:00Z",
        "labels": ["ubuntu-latest"],
        **change,
    }
    result = measurement.job_metrics(
        job, True, datetime(2026, 10, 31, tzinfo=timezone.utc)
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
    assert api.get("/one") == {"jobs": []}
    assert api.get("/one") == {"jobs": []}
    with pytest.raises(measurement.BudgetExceeded, match="quota"):
        api.get("/two")
    assert calls == [["gh", "api", "--method", "GET", "--include", "/one"]]


def test_every_attempt_explicit_and_resume(
    measurement: ModuleType, state: dict[str, Any], tmp_path: Path
) -> None:
    """Fetch attempt 1/2 explicitly and never call the latest-only jobs route."""
    private = state["repositories"]["example/private"]
    private["runs"] = [private["runs"][0]]
    private["runs"][0]["created_at"] = "2026-10-02T00:00:00Z"
    private["attempts"] = {"1": {"1": []}}
    state["repositories"] = {"example/private": private}
    calls: list[Any] = []

    class FakeAPI:
        """Only explicit attempt endpoints are available."""

        deadline = float("inf")
        stopped = ""
        requests = 1

        def pages(self, endpoint: str, field: str) -> list[dict[str, Any]]:
            """Return a completed, empty attempt."""
            calls.append((endpoint, field))
            return []

    measurement.collect(FakeAPI(), state, tmp_path / "checkpoint.json")
    assert calls == [("/repos/example/private/actions/runs/1/attempts/2/jobs", "jobs")]
    assert private["attempts"]["1"] == {"1": [], "2": []}


def test_search_cap_split_and_half_open_dedup(measurement: ModuleType) -> None:
    """Split capped searches and deduplicate inclusive API boundaries."""
    start = measurement.stamp("2026-10-01T00:00:00Z")
    end = measurement.stamp("2026-10-03T00:00:00Z")
    boundary = {"id": 1, "created_at": "2026-10-02T00:00:00Z"}
    outside = {"id": 2, "created_at": "2026-10-03T00:00:00Z"}

    class FakeAPI:
        """Return a capped parent with two uncapped inclusive child ranges."""

        count = 0

        def get(self, _endpoint: str) -> dict[str, int]:
            """Cap only the first request."""
            self.count += 1
            return {"total_count": 1000 if self.count == 1 else 2}

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
    measurement: ModuleType, tmp_path: Path
) -> None:
    """Partial pages survive, without claiming that the search was complete."""
    api = measurement.API(tmp_path, 10)
    endpoint = "/repos/example/repo/actions/runs?created=window"
    for number, attempt in enumerate((1, 3)):
        measurement.save(
            api.cache / f"{number}.json",
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
        return {
            "jobs": [
                {"id": i} for i in range(100 if endpoint.endswith("&page=1") else 1)
            ]
        }

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
