#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Require GHES repository fallbacks except for proven readiness prerequisites."""

import re
import sys
from collections.abc import Iterator
from itertools import product
from pathlib import Path
from typing import Any

import yaml
from docker_readiness_contract import (
    CHECKOUT,
    IDENTITY,
    RUN,
    check_job,
    docker_setup_indices,
    require,
)
from gha_expr import evaluate

YamlPath = tuple[str | int, ...]
RAW_REPOSITORY = re.compile(
    r"\bjob\.workflow_repository\b(?!\s*\|\|\s*'lgtm-hq/lgtm-ci')",
)


def raw_repository_paths(node: Any, path: YamlPath = ()) -> Iterator[YamlPath]:
    """Find every expression use lacking the existing immediate GHES fallback."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield from raw_repository_paths(value, (*path, key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from raw_repository_paths(value, (*path, index))
    elif isinstance(node, str):
        for expression in re.findall(r"\$\{\{(.*?)\}\}", node, re.DOTALL):
            if RAW_REPOSITORY.search(expression):
                yield path
                break


def readiness_repository_paths(workflow: dict[str, Any], name: str) -> set[YamlPath]:
    """Authorize two fields only after checking the complete mandatory sequence.

    No file or step name alone grants an exception. The shared Docker contract
    checks the exact guard body, immutable checkout, fatal barrier and ordering.
    Interpret all three actual conditions too, including older GHES runners
    without runner.environment and failed/cancelled preceding steps.
    """
    allowed: set[YamlPath] = set()
    for job_id, job in workflow.get("jobs", {}).items():
        steps = job.get("steps", [])
        if not any(step.get("run") == RUN for step in steps):
            continue
        setup = docker_setup_indices(steps)
        require(bool(setup), (name, job_id, "missing Docker setup"))
        check_job(steps, setup, (name, job_id))
        for index, step in enumerate(steps):
            if step not in (IDENTITY, CHECKOUT) and step.get("run") != RUN:
                continue
            for runner_os, environment, status in product(
                ("Linux", "Windows", "macOS"),
                ("github-hosted", "self-hosted", ""),
                ("success", "failure", "cancelled"),
            ):
                actual = evaluate(
                    step["if"],
                    {
                        "runner.os": runner_os,
                        "runner.environment": environment,
                        "job.status": status,
                    },
                )
                require(
                    actual
                    == (
                        runner_os == "Linux"
                        and environment == "github-hosted"
                        and status == "success"
                    ),
                    (name, job_id, index, "readiness condition applicability"),
                )
            prefix: YamlPath = ("jobs", job_id, "steps", index)
            if step == IDENTITY:
                allowed.add((*prefix, "env", "WORKFLOW_REPOSITORY"))
            elif step == CHECKOUT:
                allowed.add((*prefix, "with", "repository"))
    return allowed


def main(root: Path) -> None:
    """Check parsed workflow and composite-action values, including extra uses."""
    for directory in (root / ".github/workflows", root / ".github/actions"):
        for path in sorted(directory.rglob("*.y*ml")):
            document = yaml.safe_load(path.read_text())
            raw = set(raw_repository_paths(document))
            if not raw:
                continue
            allowed = readiness_repository_paths(document, path.name)
            require(
                not raw - allowed,
                (
                    str(path),
                    "job.workflow_repository requires GHES fallback",
                    raw - allowed,
                ),
            )
    print("GHES repository fallbacks and scoped readiness identities verified")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
