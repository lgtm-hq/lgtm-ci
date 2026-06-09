#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Enforce runner-image and runner-map contract across reusable workflows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
WORKFLOWS_DIR="${WORKFLOWS_DIR:-${REPO_ROOT}/.github/workflows}"

if [[ ! -d "${WORKFLOWS_DIR}" ]]; then
	echo "ERROR: workflows directory not found: ${WORKFLOWS_DIR}" >&2
	exit 1
fi

python3 - "${WORKFLOWS_DIR}" <<'PY'
"""Validate runner-image wiring across lgtm-ci reusable workflows."""
from __future__ import annotations

import re
import sys
from pathlib import Path

workflows_dir = Path(sys.argv[1])

RUNNER_PINNING_EXCEPTIONS = {
    "reusable-codeql.yml",
    "reusable-dependency-review.yml",
    "reusable-scorecards.yml",
    "reusable-semantic-pr-title.yml",
    "reusable-pr-labeler.yml",
    "reusable-publish-npm.yml",
    "reusable-publish-gem.yml",
}

DOCKER_FILE = "reusable-docker.yml"
DOCKER_INTERNAL_JOBS = {
    "classify",
    "build",
    "merge",
    "summary-validate",
    "scan",
}
DOCKER_MATRIX_RUNS_ON = {"${{ matrix.runner }}"}
RUNNER_IMAGE_RUNS_ON = "${{ inputs.runner-image }}"


def parse_jobs(content: str) -> dict[str, str]:
    """Return job id -> runs-on expression for each job in the workflow."""
    jobs_match = re.search(r"^jobs:\n", content, re.M)
    if not jobs_match:
        return {}

    jobs_section = content[jobs_match.end() :]
    jobs: dict[str, str] = {}
    for match in re.finditer(
        r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
        jobs_section,
        re.M | re.S,
    ):
        job_id = match.group(1)
        block = match.group(2)
        runs_match = re.search(r"^    runs-on: (.+)$", block, re.M)
        if runs_match:
            jobs[job_id] = runs_match.group(1).strip()
    return jobs


def has_runner_image_input(content: str) -> bool:
    return bool(re.search(r"^\s+runner-image:", content, re.M))


def has_runner_map_input(content: str) -> bool:
    return bool(re.search(r"^\s+runner-map:", content, re.M))


def is_script_backed(content: str) -> bool:
    return "scripts/ci/" in content


def runner_image_default(content: str) -> str | None:
    match = re.search(
        r"runner-image:\n(?:.*\n)*?        default: (?:\"([^\"]+)\"|'([^']+)')",
        content,
    )
    if not match:
        return None
    return match.group(1) or match.group(2)


violations: list[str] = []

for workflow in sorted(workflows_dir.glob("reusable-*.yml")):
    content = workflow.read_text()
    rel = workflow.name
    jobs = parse_jobs(content)
    has_runner = has_runner_image_input(content)

    if rel == DOCKER_FILE:
        if not has_runner_map_input(content):
            violations.append(f"{rel}: missing runner-map input")
        for job_id, runs_on in jobs.items():
            if runs_on in DOCKER_MATRIX_RUNS_ON:
                continue
            if job_id in DOCKER_INTERNAL_JOBS:
                if runs_on != "ubuntu-24.04":
                    violations.append(
                        f"{rel}: job {job_id} must use ubuntu-24.04 coordinator runner "
                        f"(found {runs_on!r})",
                    )
                continue
            if re.fullmatch(r"ubuntu-[\w.-]+", runs_on):
                violations.append(
                    f"{rel}: job {job_id} hardcodes runs-on {runs_on!r}",
                )
        continue

    if rel in RUNNER_PINNING_EXCEPTIONS:
        continue

    if has_runner:
        default = runner_image_default(content)
        if default == "ubuntu-latest":
            violations.append(
                f"{rel}: runner-image default must be ubuntu-24.04 (found ubuntu-latest)",
            )
        for job_id, runs_on in jobs.items():
            if runs_on != RUNNER_IMAGE_RUNS_ON:
                if re.fullmatch(r"ubuntu-[\w.-]+", runs_on):
                    violations.append(
                        f"{rel}: job {job_id} hardcodes runs-on {runs_on!r} "
                        f"but runner-image input is defined",
                    )
                elif "${{ matrix." not in runs_on:
                    violations.append(
                        f"{rel}: job {job_id} runs-on {runs_on!r} "
                        f"must use ${{ inputs.runner-image }}",
                    )
        continue

    if is_script_backed(content):
        for job_id, runs_on in jobs.items():
            if re.fullmatch(r"ubuntu-[\w.-]+", runs_on):
                violations.append(
                    f"{rel}: script-backed reusable hardcodes runs-on {runs_on!r} "
                    f"on job {job_id} without runner-image input",
                )

if violations:
    for violation in violations:
        print(violation, file=sys.stderr)
    print(
        f"ERROR: {len(violations)} reusable workflow runner contract violation(s)",
        file=sys.stderr,
    )
    sys.exit(1)

print("OK: reusable workflow runner contract satisfied")
PY
