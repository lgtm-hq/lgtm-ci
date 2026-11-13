#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check all Docker setup jobs and replay their applicable readiness steps."""

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml
from bats_subprocess import trace_fds
from gha_expr import Value, evaluate

Step = dict[str, Any]

SCRIPT = "scripts/ci/docker/wait-for-harden-runner.sh"
RUN = f"bash .lgtm-ci-readiness/{SCRIPT}"
IDENTITY_NAME = "Require workflow readiness identity"
CHECKOUT_NAME = "Checkout workflow readiness helper"
APPLICABLE = "${{ runner.os == 'Linux' && runner.environment == 'github-hosted' }}"
IDENTITY = {
    "name": IDENTITY_NAME,
    "if": APPLICABLE,
    "shell": "bash",
    "env": {
        "WORKFLOW_REPOSITORY": "${{ job.workflow_repository }}",
        "WORKFLOW_SHA": "${{ job.workflow_sha }}",
    },
    # Three lines, so it stays within the inline-run ratchet (#1450). Under
    # the runner's `bash -e` a failed [[ ]] before && does not exit.
    "run": (
        '[[ -n "$WORKFLOW_REPOSITORY" && '
        '"$WORKFLOW_SHA" =~ ^[0-9a-f]{40}$ ]] && exit 0\n'
        'echo "::error::Immutable workflow identity is required '
        'for Docker readiness"\n'
        "exit 1\n"
    ),
}
CHECKOUT_WITH: dict[str, object] = {
    "repository": "${{ job.workflow_repository }}",
    "ref": "${{ job.workflow_sha }}",
    "path": ".lgtm-ci-readiness",
    "sparse-checkout": SCRIPT,
    "sparse-checkout-cone-mode": False,
    "persist-credentials": False,
}
CHECKOUT = {
    "name": CHECKOUT_NAME,
    "if": APPLICABLE,
    "uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
    "with": CHECKOUT_WITH,
}
# A reusable that takes the optional tooling token (#1451) hands it to this
# checkout too, since it reads the tooling repository. Until the last Docker
# reusable is converted, the form without the token is accepted as well.
CHECKOUT_WITH_TOKEN: dict[str, object] = {
    **CHECKOUT,
    "with": {
        **CHECKOUT_WITH,
        "token": "${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}",
    },
}
CHECKOUTS = (CHECKOUT, CHECKOUT_WITH_TOKEN)
EXPECTED = {
    ("reusable-docker-build.yml", "build"),
    ("reusable-docker-multiplatform-validate.yml", "build-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "build-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "verify-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "health-check-per-platform"),
    ("reusable-docker-multiplatform-publish.yml", "merge"),
    ("reusable-docker-smoke-test.yml", "smoke-test"),
}


def load_yaml(path: Path) -> Any:
    """Use PyYAML's equivalent compiled safe loader when already available."""
    loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
    return yaml.load(path.read_text(), Loader=loader)


def require(condition: bool, detail: object) -> None:
    """Keep contract failures active even when Python runs with optimization."""
    if not condition:
        raise AssertionError(detail)


def named_step(steps: list[Step], name: str, detail: tuple[str, str]) -> int:
    """Require exactly one identity/checkout step without relying on assertions."""
    matches = [i for i, step in enumerate(steps) if step.get("name") == name]
    require(len(matches) == 1, (*detail, f"missing or duplicate {name}"))
    return matches[0]


def docker_setup_indices(steps: list[Step]) -> list[int]:
    """Locate the Docker action boundary shared by both identity contracts."""
    return [
        index
        for index, step in enumerate(steps)
        if step.get("uses", "").startswith(
            ("docker/setup-qemu-action@", "docker/setup-buildx-action@")
        )
    ]


def check_job(steps: list[Step], setup: list[int], detail: tuple[str, str]) -> None:
    """Bind one job's barrier to its workflow revision and preserve caller refs."""
    barriers = [i for i, step in enumerate(steps) if step.get("run") == RUN]
    require(len(barriers) == 1, (*detail, "missing barrier"))
    barrier = barriers[0]
    require(
        steps[barrier]
        == {
            "name": "Wait for hardener Docker readiness",
            "if": APPLICABLE,
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
        steps[checkout] in CHECKOUTS,
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
                step["with"]["ref"] == "${{ job.workflow_sha || "
                "inputs.tooling-ref || 'tooling-ref-required' }}",
                (*detail, "bootstrap must follow job.workflow_sha (#1368)"),
            )
        if step.get("name", "").startswith("Checkout repository"):
            require(
                step["with"]["ref"] == "${{ inputs.source-ref != '' && "
                "inputs.source-ref || github.sha }}",
                (*detail, "preserve independent app source"),
            )


def replay(steps: list[Step], root: Path) -> None:
    """Evaluate actual step conditions and simulate only checkout/Docker setup.

    The narrow checkout copies the workflow tree's helper offline; the exact
    contract separately pins its repository, revision and sparse settings.
    Shell steps execute unchanged, so a missing helper cannot be concealed.
    """
    context: dict[str, Value] = {
        "runner.os": os.environ["RUNNER_OS"],
        "runner.environment": os.environ["RUNNER_ENVIRONMENT"],
        "matrix.qemu": True,
    }
    for step in steps:
        is_setup = step.get("uses", "").startswith(
            ("docker/setup-qemu-action@", "docker/setup-buildx-action@")
        )
        if (
            step.get("name")
            not in (
                IDENTITY_NAME,
                CHECKOUT_NAME,
                "Wait for hardener Docker readiness",
            )
            and not is_setup
        ):
            continue
        if not evaluate(str(step.get("if", "success()")), context):
            continue
        print(f"replay: {step['name']}", flush=True)
        if is_setup:
            subprocess.run(
                ["docker", "buildx", "inspect", "--bootstrap"],
                check=True,
                pass_fds=trace_fds(os.environ),
            )
            return
        if step.get("name") == CHECKOUT_NAME:
            target = Path(step["with"]["path"]) / step["with"]["sparse-checkout"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / SCRIPT, target)
        else:
            subprocess.run(
                ["bash", "-e", "-c", step["run"]],
                check=True,
                pass_fds=trace_fds(os.environ),
            )


def main() -> None:
    """Check all seven callers or replay a selected job's actual setup steps."""
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
        jobs = load_yaml(workflow)["jobs"]
        for job_id, job in jobs.items():
            detail = (workflow.name, job_id)
            steps = job.get("steps", [])
            setup = docker_setup_indices(steps)
            if not setup:
                continue
            found.add((workflow.name, job_id))
            if mode == "replay":
                if (workflow.name, job_id) != selected:
                    continue
                replay(steps, root)
                continue
            check_job(steps, setup, detail)
    require(found == EXPECTED, ("Docker setup caller map drift", found ^ EXPECTED))
    if mode == "check":
        print(f"{len(found)} Docker setup jobs require hardener completion")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
