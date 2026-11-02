#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check all Docker setup jobs and replay validate/build-per-platform commands."""

import shlex
import sys
from pathlib import Path

import yaml

SCRIPT = "scripts/ci/docker/wait-for-harden-runner.sh"
RUN = f"bash .lgtm-ci-tooling/{SCRIPT}"
EXPECTED = {
    ("reusable-docker-build.yml", "build"),
    ("reusable-docker-multiplatform-validate.yml", "build-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "build-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "verify-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "health-check-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "merge"),
    ("reusable-docker-smoke-test.yml", "smoke-test"),
}


def require(condition: bool, detail: object) -> None:
    """Keep contract failures active even when Python runs with optimization."""
    if not condition:
        raise AssertionError(detail)


def main() -> None:
    """Check all seven callers or emit only validate's setup command sequence."""
    mode, root_arg = sys.argv[1:]
    root = Path(root_arg)
    found = set()
    for workflow in sorted((root / ".github/workflows").glob("reusable-docker*.yml")):
        jobs = yaml.safe_load(workflow.read_text())["jobs"]
        for job_id, job in jobs.items():
            steps = job.get("steps", [])
            setup = [
                index
                for index, step in enumerate(steps)
                if step.get("uses", "").startswith(
                    ("docker/setup-qemu-action@", "docker/setup-buildx-action@")
                )
            ]
            if not setup:
                continue
            found.add((workflow.name, job_id))
            barriers = [i for i, step in enumerate(steps) if step.get("run") == RUN]
            if mode == "commands":
                if (workflow.name, job_id) != (
                    "reusable-docker-multiplatform-validate.yml",
                    "build-per-platform",
                ):
                    continue
                for i in barriers:
                    if i < min(setup):
                        print(f"bash {shlex.quote(str(root / SCRIPT))}")
                print("docker buildx inspect --bootstrap")
                continue
            require(len(barriers) == 1, (workflow.name, job_id, "missing barrier"))
            barrier = barriers[0]
            require(
                steps[barrier]
                == {
                    "name": "Wait for hardener Docker readiness",
                    "shell": "bash",
                    "run": RUN,
                },
                (workflow.name, job_id, "barrier must fail closed"),
            )
            require(barrier < min(setup), (workflow.name, job_id, "late barrier"))
            hardener = next(
                i
                for i, step in enumerate(steps)
                if step.get("uses", "").startswith("step-security/harden-runner@")
            )
            tooling = next(i for i, s in enumerate(steps) if s.get("id") == "egress")
            require(
                hardener < tooling < barrier,
                (workflow.name, job_id, "hardener/tooling/barrier order"),
            )
            require(
                "scripts/ci/" in steps[tooling]["with"]["sparse-checkout-extra"],
                (workflow.name, job_id, "tooling checkout must include scripts/ci/"),
            )
    require(found == EXPECTED, ("Docker setup caller map drift", found ^ EXPECTED))
    if mode == "check":
        print(f"{len(found)} Docker setup jobs require hardener completion")


if __name__ == "__main__":
    main()
