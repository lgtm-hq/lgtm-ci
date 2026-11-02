#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check all Docker setup jobs and replay validate/build-per-platform commands."""

import sys
from pathlib import Path
from typing import Any

import yaml

Step = dict[str, Any]

SCRIPT = "scripts/ci/docker/wait-for-harden-runner.sh"
RUN = f"bash .lgtm-ci-readiness/{SCRIPT}"
IDENTITY_NAME = "Require workflow readiness identity"
CHECKOUT_NAME = "Checkout workflow readiness helper"
IDENTITY = {
    "name": IDENTITY_NAME,
    "shell": "bash",
    "env": {
        "WORKFLOW_REPOSITORY": "${{ job.workflow_repository }}",
        "WORKFLOW_SHA": "${{ job.workflow_sha }}",
    },
    "run": (
        'if [[ -z "$WORKFLOW_REPOSITORY" || '
        '! "$WORKFLOW_SHA" =~ ^[0-9a-f]{40}$ ]]; then\n'
        '  echo "::error::Immutable workflow identity is required '
        'for Docker readiness"\n'
        "  exit 1\n"
        "fi\n"
    ),
}
CHECKOUT = {
    "name": CHECKOUT_NAME,
    "uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
    "with": {
        "repository": "${{ job.workflow_repository }}",
        "ref": "${{ job.workflow_sha }}",
        "path": ".lgtm-ci-readiness",
        "sparse-checkout": SCRIPT,
        "sparse-checkout-cone-mode": False,
        "persist-credentials": False,
    },
}
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


def named_step(steps: list[Step], name: str, detail: tuple[str, str]) -> int:
    """Require exactly one identity/checkout step without relying on assertions."""
    matches = [i for i, step in enumerate(steps) if step.get("name") == name]
    require(len(matches) == 1, (*detail, f"missing or duplicate {name}"))
    return matches[0]


def check_job(steps: list[Step], setup: list[int], detail: tuple[str, str]) -> None:
    """Bind one job's barrier to its workflow revision and preserve caller refs."""
    barriers = [i for i, step in enumerate(steps) if step.get("run") == RUN]
    require(len(barriers) == 1, (*detail, "missing barrier"))
    barrier = barriers[0]
    require(
        steps[barrier]
        == {
            "name": "Wait for hardener Docker readiness",
            "shell": "bash",
            "run": RUN,
        },
        (*detail, "barrier must fail closed"),
    )
    require(barrier < min(setup), (*detail, "late barrier"))
    hardener = next(
        (
            i
            for i, step in enumerate(steps)
            if step.get("uses", "").startswith("step-security/harden-runner@")
        ),
        -1,
    )
    tooling = next(
        (i for i, step in enumerate(steps) if step.get("id") == "egress"),
        -1,
    )
    require(
        hardener >= 0,
        (*detail, "missing harden-runner step"),
    )
    require(tooling >= 0, (*detail, "missing tooling checkout"))
    identity = named_step(steps, IDENTITY_NAME, detail)
    checkout = named_step(steps, CHECKOUT_NAME, detail)
    require(
        steps[identity] == IDENTITY,
        (*detail, "workflow identity must fail closed"),
    )
    require(
        steps[checkout] == CHECKOUT,
        (*detail, "readiness checkout must pin own workflow helper"),
    )
    require(
        hardener < tooling < identity < checkout < barrier,
        (*detail, "hardener/tooling/identity/checkout/barrier order"),
    )
    require(
        "scripts/ci/" in steps[tooling]["with"]["sparse-checkout-extra"],
        (*detail, "tooling checkout must include scripts/ci/"),
    )
    require(
        steps[tooling]["with"]["tooling-ref"]
        == "${{ inputs.tooling-ref != '' && inputs.tooling-ref || "
        "job.workflow_sha }}",
        (*detail, "preserve tooling override"),
    )
    for step in steps:
        if step.get("name") == "Checkout lgtm-ci tooling":
            require(
                step["with"]["ref"] == "${{ inputs.tooling-ref != '' && "
                "inputs.tooling-ref || job.workflow_sha || 'tooling-ref-required' }}",
                (*detail, "preserve tooling bootstrap override"),
            )
        if step.get("name", "").startswith("Checkout repository"):
            require(
                step["with"]["ref"] == "${{ inputs.source-ref != '' && "
                "inputs.source-ref || github.sha }}",
                (*detail, "preserve independent app source"),
            )


def main() -> None:
    """Check all seven callers or emit a selected job's actual setup commands."""
    mode, root_arg, *caller = sys.argv[1:]
    root = Path(root_arg)
    if mode == "callers":
        for workflow_name, job_id in sorted(EXPECTED):
            print(workflow_name, job_id)
        return
    selected = (
        tuple(caller)
        if caller
        else (
            "reusable-docker-multiplatform-validate.yml",
            "build-per-platform",
        )
    )
    require(selected in EXPECTED, ("unknown Docker setup caller", selected))
    found = set()
    for workflow in sorted((root / ".github/workflows").glob("reusable-docker*.yml")):
        jobs = yaml.safe_load(workflow.read_text())["jobs"]
        for job_id, job in jobs.items():
            detail = (workflow.name, job_id)
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
            if mode == "commands":
                if (workflow.name, job_id) != selected:
                    continue
                for step in steps[: min(setup)]:
                    if step.get("name") == IDENTITY_NAME:
                        print(step["run"], end="")
                    if step.get("name") == "Wait for hardener Docker readiness":
                        # Preserve the workflow's path; do not substitute the
                        # canonical source and accidentally conceal provenance bugs.
                        print(step["run"])
                print("docker buildx inspect --bootstrap")
                continue
            check_job(steps, setup, detail)
    require(found == EXPECTED, ("Docker setup caller map drift", found ^ EXPECTED))
    if mode == "check":
        print(f"{len(found)} Docker setup jobs require hardener completion")


if __name__ == "__main__":
    main()
