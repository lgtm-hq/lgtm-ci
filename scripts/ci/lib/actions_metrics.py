# SPDX-License-Identifier: MIT
"""Conservative runner classification and per-job Actions usage metrics."""

from __future__ import annotations

import math
from datetime import datetime, timezone
from typing import Any

ROW = dict[str, Any]


def stamp(value: str) -> datetime:
    """Parse an ISO timestamp; require an explicit timezone."""
    if not isinstance(value, str):
        raise TypeError("timestamp must be a string")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamps must include a timezone")
    return result.astimezone(timezone.utc)


def runner_kind(job: ROW) -> tuple[str, int | None]:
    """Classify standard hosted labels conservatively; larger/custom is unknown."""
    labels = [str(label).lower() for label in job.get("labels") or []]
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
    kinds = {standard[label] for label in labels if label in standard}
    if len(kinds) == 1 and all(label in standard for label in labels):
        return kinds.pop()
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
