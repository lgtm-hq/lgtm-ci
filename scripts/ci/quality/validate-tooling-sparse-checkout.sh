#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail when reusable workflows sparse-checkout tooling composites without scripts/ci/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
WORKFLOWS_DIR="${WORKFLOWS_DIR:-${REPO_ROOT}/.github/workflows}"
ACTIONS_DIR="${ACTIONS_DIR:-${REPO_ROOT}/.github/actions}"

if [[ ! -d "${WORKFLOWS_DIR}" ]]; then
	echo "ERROR: workflows directory not found: ${WORKFLOWS_DIR}" >&2
	exit 1
fi

if [[ ! -d "${ACTIONS_DIR}" ]]; then
	echo "ERROR: actions directory not found: ${ACTIONS_DIR}" >&2
	exit 1
fi

python3 - "${WORKFLOWS_DIR}" "${ACTIONS_DIR}" <<'PY'
"""Validate lgtm-ci tooling sparse-checkout includes scripts/ci/ when needed."""
from __future__ import annotations

import re
import sys
from pathlib import Path

workflows_dir = Path(sys.argv[1])
actions_dir = Path(sys.argv[2])

script_composites: set[str] = set()
for action_yml in actions_dir.glob("*/action.yml"):
    text = action_yml.read_text()
    if re.search(r"scripts/ci|SCRIPTS_DIR/ci/|GITHUB_ACTION_PATH.*scripts", text):
        script_composites.add(action_yml.parent.name)
script_composites -= {"harden-runner", "resolve-egress-allowlist"}


def parse_sparse(block: str) -> list[str]:
    match = re.search(r"sparse-checkout:\s*\|\s*\n((?:\s{12}.+\n)+)", block)
    if match:
        return [line[12:].strip() for line in match.group(1).splitlines() if line.strip()]
    single = re.search(r"sparse-checkout:\s*([^\n]+)", block)
    return [single.group(1).strip()] if single else []


violations: list[str] = []
for workflow in sorted(workflows_dir.glob("reusable-*.yml")):
    content = workflow.read_text()
    if ".lgtm-ci-tooling/.github/actions/" not in content:
        continue

    for job_chunk in re.split(r"(?=^  [a-zA-Z][\w-]*:\n)", content, flags=re.M):
        if "Checkout lgtm-ci tooling" not in job_chunk:
            continue

        job_match = re.match(r"  ([\w-]+):", job_chunk)
        job_id = job_match.group(1) if job_match else "?"

        for block in re.split(r"(?=      - name: Checkout lgtm-ci tooling)", job_chunk):
            if "Checkout lgtm-ci tooling" not in block:
                continue

            paths = parse_sparse(block)
            block_composites = set(
                re.findall(
                    r"uses:\s+\./\.lgtm-ci-tooling/\.github/actions/([^\s#]+)",
                    block,
                )
            ) & script_composites

            has_scripts = any(path.startswith("scripts/ci") for path in paths)
            has_actions = any(path.startswith(".github/actions") for path in paths)
            if block_composites and has_actions and not has_scripts:
                composites = ", ".join(sorted(block_composites))
                path_list = ", ".join(paths)
                violations.append(
                    f"{workflow.name}:{job_id}: sparse-checkout missing scripts/ci/ "
                    f"(paths: {path_list}; composites: {composites})"
                )

if violations:
    print("ERROR: tooling sparse-checkout contract violations:", file=sys.stderr)
    for violation in violations:
        print(f"  - {violation}", file=sys.stderr)
    sys.exit(1)

print("OK: reusable workflow tooling sparse-checkout satisfies scripts/ci/ policy")
PY
