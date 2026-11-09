#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail when a reusable job runs a script that (transitively) sources
#          lib/testing/results.sh without checking out schemas/ with the tooling.
#
# results_v1_validate reads schemas/results.v1.json from the tooling
# checkout, so every job that reaches it must list `schemas/` in its tooling
# sparse-checkout (sparse-checkout-extra of checkout-and-harden).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
WORKFLOWS_DIR="${WORKFLOWS_DIR:-${REPO_ROOT}/.github/workflows}"
ACTIONS_DIR="${ACTIONS_DIR:-${REPO_ROOT}/.github/actions}"
SCRIPTS_CI_DIR="${SCRIPTS_CI_DIR:-${REPO_ROOT}/scripts/ci}"

for dir in "${WORKFLOWS_DIR}" "${ACTIONS_DIR}" "${SCRIPTS_CI_DIR}"; do
	if [[ ! -d "${dir}" ]]; then
		echo "ERROR: directory not found: ${dir}" >&2
		exit 1
	fi
done

python3 - "${WORKFLOWS_DIR}" "${ACTIONS_DIR}" "${SCRIPTS_CI_DIR}" <<'PY'
"""Validate jobs that reach lib/testing/results.sh also check out schemas/."""
from __future__ import annotations

import re
import sys
from pathlib import Path

workflows_dir = Path(sys.argv[1])
actions_dir = Path(sys.argv[2])
scripts_dir = Path(sys.argv[3])

RESULTS_LIB = "lib/testing/results.sh"

# --- Scripts that source results.sh, directly or through other libraries ----
all_scripts = {p.relative_to(scripts_dir).as_posix(): p for p in scripts_dir.rglob("*.sh")}

SOURCE_RE = re.compile(r'^\s*(?:source|\.)\s+"?([^"\s;]+\.sh)"?', re.M)


def sourced(rel: str) -> set[str]:
    """Resolve the scripts that `rel` sources (suffix match on the path tail)."""
    found: set[str] = set()
    for arg in SOURCE_RE.findall(all_scripts[rel].read_text()):
        tail = re.sub(r"^(?:.*\}|\$\w+)", "", arg)
        tail = re.sub(r"^(?:\.{0,2}/)+", "", tail.lstrip("/"))
        tail = re.sub(r"^(?:\.\./)+", "", tail)
        if not tail:
            continue
        matches = [c for c in all_scripts if c == tail or c.endswith("/" + tail)]
        if not matches:
            matches = [c for c in all_scripts if Path(c).name == Path(tail).name]
        found.update(matches)
    return found


reaches: dict[str, bool] = {}


def reaches_results(rel: str, seen: frozenset[str] = frozenset()) -> bool:
    if rel == RESULTS_LIB:
        return True
    if rel in reaches:
        return reaches[rel]
    if rel in seen:
        return False
    result = any(reaches_results(dep, seen | {rel}) for dep in sourced(rel))
    reaches[rel] = result
    return result


needs_schema_scripts = {rel for rel in all_scripts if reaches_results(rel)}


def script_refs(text: str) -> set[str]:
    """Script paths (relative to scripts/ci) referenced in a run/action body."""
    refs: set[str] = set()
    for match in re.finditer(r"(?:scripts/ci|\$\{?SCRIPTS_DIR\}?/ci)/([\w./-]+\.sh)", text):
        refs.add(match.group(1))
    return refs


# --- Composite actions that run such scripts (following nested composites) --
action_text = {p.parent.name: p.read_text() for p in actions_dir.glob("*/action.yml")}
NESTED_RE = re.compile(r"uses:\s*\./(?:\.lgtm-ci-tooling/)?\.github/actions/([\w-]+)")


def action_needs_schema(name: str, seen: frozenset[str] = frozenset()) -> bool:
    text = action_text.get(name)
    if text is None or name in seen:
        return False
    if script_refs(text) & needs_schema_scripts:
        return True
    return any(action_needs_schema(n, seen | {name}) for n in NESTED_RE.findall(text))


needs_schema_actions = {name for name in action_text if action_needs_schema(name)}


# --- Workflow jobs -----------------------------------------------------------
def tooling_paths(job: str) -> list[str]:
    paths: list[str] = []
    for key in ("sparse-checkout-extra", "sparse-checkout"):
        for match in re.finditer(rf"{key}:\s*\|\s*\n((?:[ ]{{10,}}\S.*\n?)+)", job):
            paths += [line.strip() for line in match.group(1).splitlines() if line.strip()]
    return paths


violations: list[str] = []
for workflow in sorted(workflows_dir.glob("reusable-*.yml")):
    content = workflow.read_text()
    if ".lgtm-ci-tooling" not in content:
        continue
    for job in re.split(r"(?=^  [_a-zA-Z][\w-]*:\n)", content, flags=re.M):
        job_match = re.match(r"  ([\w-]+):", job)
        if not job_match or "Checkout lgtm-ci tooling" not in job:
            continue
        reasons = sorted(
            {
                f"action {name}"
                for name in re.findall(r"\./\.lgtm-ci-tooling/\.github/actions/([\w-]+)", job)
                if name in needs_schema_actions
            }
            | {
                f"script {rel}"
                for rel in script_refs(job)
                if rel in needs_schema_scripts
            }
        )
        if not reasons:
            continue
        paths = {p.removesuffix("/") for p in tooling_paths(job)}
        if "schemas" not in paths:
            violations.append(
                f"{workflow.name}: job '{job_match.group(1)}' uses {', '.join(reasons)} "
                "(reaches lib/testing/results.sh) but its sparse-checkout-extra lacks 'schemas/'"
            )

if violations:
    print("ERROR: results.sh consumers need schemas/ in the tooling checkout:", file=sys.stderr)
    for violation in violations:
        print(f"  - {violation}", file=sys.stderr)
    sys.exit(1)

print("OK: every job reaching lib/testing/results.sh checks out schemas/")
PY
