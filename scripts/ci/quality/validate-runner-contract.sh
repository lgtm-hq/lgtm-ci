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

# Reusables documented in docs/workflow-contract.md as exempt from the
# timeout-minutes input requirement. Currently every reusable exposes it.
TIMEOUT_MINUTES_EXCEPTIONS: set[str] = set()

# Per-job exemptions from the requirement that every runs-on job declares
# timeout-minutes (literal or input-wired). Entries are "<file>.yml:<job-id>"
# and MUST be documented in docs/workflow-contract.md "Job timeouts". The
# 10-min failure-reporter legs are NOT listed here: they satisfy the rule with
# their own literal cap. Currently no job needs an exemption.
TIMEOUT_PER_JOB_EXCEPTIONS: set[str] = set()

# Docker family (#381): reusable-docker.yml is the thin orchestrator
# (classify + nested workflow calls); the focused reusables own the
# build/merge jobs. Internal coordinator jobs are pinned to ubuntu-24.04
# and are not caller-pinnable; per-platform matrix jobs use the
# runner-map-resolved ${{ matrix.runner }} expression.
DOCKER_FAMILY: dict[str, set[str]] = {
    "reusable-docker.yml": {"classify"},
    "reusable-docker-build.yml": {"build", "scan"},
    "reusable-docker-multiplatform.yml": {
        "build-per-platform",
        "verify-per-platform",
        "health-check-per-platform",
        "merge",
        "summary-validate",
        "scan",
    },
}
# Only the orchestrator exposes runner-map; the multiplatform reusable
# receives the already-resolved matrix from the classify job.
DOCKER_RUNNER_MAP_FILES = {"reusable-docker.yml"}
DOCKER_MATRIX_RUNS_ON = {"${{ matrix.runner }}"}
RUNNER_IMAGE_RUNS_ON = "${{ inputs.runner-image }}"


def iter_job_blocks(content: str) -> list[tuple[str, str]]:
    """Return (job id, job body) pairs for each job in the workflow."""
    jobs_match = re.search(r"^jobs:\n", content, re.M)
    if not jobs_match:
        return []

    jobs_section = content[jobs_match.end() :]
    return [
        (match.group(1), match.group(2))
        for match in re.finditer(
            r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
            jobs_section,
            re.M | re.S,
        )
    ]


def parse_jobs(content: str) -> dict[str, str]:
    """Return job id -> runs-on expression for each runs-on job."""
    jobs: dict[str, str] = {}
    for job_id, block in iter_job_blocks(content):
        runs_match = re.search(r"^    runs-on: (.+)$", block, re.M)
        if runs_match:
            jobs[job_id] = runs_match.group(1).strip()
    return jobs


def jobs_missing_timeout(content: str, rel: str) -> list[str]:
    """Return runs-on job ids lacking a job-level timeout-minutes.

    A job satisfies the contract with either a literal ``timeout-minutes:``
    or one wired to ``${{ inputs.timeout-minutes }}``. Jobs listed in
    TIMEOUT_PER_JOB_EXCEPTIONS are skipped.
    """
    missing: list[str] = []
    for job_id, block in iter_job_blocks(content):
        if not re.search(r"^    runs-on: ", block, re.M):
            continue
        if f"{rel}:{job_id}" in TIMEOUT_PER_JOB_EXCEPTIONS:
            continue
        if not re.search(r"^    timeout-minutes:", block, re.M):
            missing.append(job_id)
    return missing


def has_runner_image_input(content: str) -> bool:
    return bool(re.search(r"^\s+runner-image:", content, re.M))


def has_runner_map_input(content: str) -> bool:
    return bool(re.search(r"^\s+runner-map:", content, re.M))


def has_timeout_minutes_input(content: str) -> bool:
    return bool(re.search(r"^      timeout-minutes:", content, re.M))


def timeout_minutes_input_is_number(content: str) -> bool:
    match = re.search(
        r"^      timeout-minutes:\n(?:        .+\n)+",
        content,
        re.M,
    )
    if not match:
        return False
    return bool(re.search(r"^        type: number$", match.group(0), re.M))


def uses_timeout_minutes_input(content: str) -> bool:
    return "timeout-minutes: ${{ inputs.timeout-minutes }}" in content


def is_script_backed(content: str) -> bool:
    return "scripts/ci/" in content


def runner_image_default(content: str) -> str | None:
    match = re.search(
        r"runner-image:\n(?:.*\n)*?"
        r"        default: (?:\"([^\"]+)\"|'([^']+)'|([^\s#]+))",
        content,
    )
    if not match:
        return None
    return match.group(1) or match.group(2) or match.group(3)


violations: list[str] = []

for workflow in sorted(workflows_dir.glob("reusable-*.yml")):
    content = workflow.read_text()
    rel = workflow.name
    jobs = parse_jobs(content)
    has_runner = has_runner_image_input(content)

    if rel not in TIMEOUT_MINUTES_EXCEPTIONS:
        if not has_timeout_minutes_input(content):
            violations.append(f"{rel}: missing timeout-minutes input")
        else:
            if not timeout_minutes_input_is_number(content):
                violations.append(
                    f"{rel}: timeout-minutes input is not type: number",
                )
            if not uses_timeout_minutes_input(content):
                violations.append(
                    f"{rel}: timeout-minutes input is never applied to a job",
                )

    for job_id in jobs_missing_timeout(content, rel):
        violations.append(
            f"{rel}: job {job_id} runs-on without timeout-minutes",
        )

    if rel in DOCKER_FAMILY:
        if rel in DOCKER_RUNNER_MAP_FILES and not has_runner_map_input(content):
            violations.append(f"{rel}: missing runner-map input")
        for job_id, runs_on in jobs.items():
            if runs_on in DOCKER_MATRIX_RUNS_ON:
                continue
            if job_id in DOCKER_FAMILY[rel]:
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
