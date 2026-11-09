#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the tooling-ref divergence guard (#1368)
#
# A tooling-ref that checks out a commit other than job.workflow_sha runs new
# workflow YAML against old scripts. Every reusable that exposes tooling-ref
# must therefore expose the tooling-ref-allow-divergence escape hatch and feed
# the guard, either through checkout-and-harden or through the inline guard
# step that follows the inline warning step.

load "../../helpers/common"

WORKFLOWS="${PROJECT_ROOT}/.github/workflows"
ACTION="${PROJECT_ROOT}/.github/actions/checkout-and-harden/action.yml"
SCRIPT=".github/actions/checkout-and-harden/check-tooling-ref-divergence.sh"

# Reusables where a differing tooling-ref is the point: the recovery trio runs
# newer tooling against an older release, and validate-lintro-version bootstraps
# from a base-ref tooling-ref with a head-ref fallback.
EXEMPT=(
	reusable-release-recover.yml
	reusable-release-recover-plan.yml
	reusable-release-recover-resume.yml
	reusable-validate-lintro-version.yml
)

# Print "<workflow>: <problem>" lines; empty output means the contract holds.
_check() {
	local dir="$1"
	shift
	"$PY" - "$dir" "$@" <<'PY'
import sys
from pathlib import Path

import yaml

workflows = Path(sys.argv[1])
exempt = set(sys.argv[2:])
BOOTSTRAP = ".github/actions/checkout-and-harden"
COMPOSITE = "checkout-and-harden"
ALLOW = "${{ inputs.tooling-ref-allow-divergence }}"
SHA = "${{ job.workflow_sha }}"
SCRIPT_NAME = "check-tooling-ref-divergence.sh"
# The composite (and so the guard) must always come from the workflow's own
# commit; tooling-ref only steers the scripts tree inside checkout-and-harden.
BOOTSTRAP_REF = "${{ job.workflow_sha || inputs.tooling-ref || 'tooling-ref-required' }}"
problems = []

for path in sorted(workflows.glob("reusable-*.yml")):
    if path.name in exempt:
        continue
    doc = yaml.safe_load(path.read_text())
    triggers = doc.get("on", doc.get(True)) or {}
    inputs = (triggers.get("workflow_call") or {}).get("inputs") or {}
    if "tooling-ref" not in inputs:
        continue
    flag = inputs.get("tooling-ref-allow-divergence")
    if not flag:
        problems.append(f"{path.name}: missing tooling-ref-allow-divergence input")
    elif flag.get("type") != "boolean" or flag.get("default") is not False:
        problems.append(f"{path.name}: tooling-ref-allow-divergence must be boolean, default false")
    elif "GHES/mirror escape hatch only" not in flag.get("description", ""):
        problems.append(f"{path.name}: tooling-ref-allow-divergence must be described as a GHES/mirror escape hatch")
    guard_steps = 0
    for job_id, job in (doc.get("jobs") or {}).items():
        steps = job.get("steps") or []
        has_composite = any(COMPOSITE in str(s.get("uses", "")) for s in steps)
        for step in steps:
            uses = str(step.get("uses", ""))
            with_ = step.get("with") or {}
            if COMPOSITE in uses:
                if with_.get("tooling-ref-allow-divergence") != ALLOW:
                    problems.append(f"{path.name}:{job_id}: checkout-and-harden lacks tooling-ref-allow-divergence")
                if with_.get("workflow-sha") != SHA:
                    problems.append(f"{path.name}:{job_id}: checkout-and-harden lacks workflow-sha")
                guard_steps += 1
            if (
                has_composite
                and uses.startswith("actions/checkout@")
                and with_.get("path") == ".lgtm-ci-tooling"
                and BOOTSTRAP not in with_.get("sparse-checkout", "").split()
            ):
                problems.append(f"{path.name}:{job_id}: tooling checkout bypasses checkout-and-harden")
            if (
                has_composite
                and uses.startswith("actions/checkout@")
                and with_.get("path") == ".lgtm-ci-tooling"
                and BOOTSTRAP in with_.get("sparse-checkout", "").split()
                and with_.get("ref") != BOOTSTRAP_REF
            ):
                problems.append(f"{path.name}:{job_id}: bootstrap ref must be {BOOTSTRAP_REF}")
            if SCRIPT_NAME in str(step.get("run", "")):
                env = step.get("env") or {}
                if (
                    env.get("TOOLING_REF_OVERRIDE") != "${{ inputs.tooling-ref }}"
                    or env.get("WORKFLOW_SHA") != SHA
                    or env.get("ALLOW_DIVERGENCE") != ALLOW
                ):
                    problems.append(f"{path.name}:{job_id}: inline guard step has the wrong env")
                guard_steps += 1
        warns = any("warn-tooling-ref-override.sh" in str(s.get("run", "")) for s in steps)
        guards = any(SCRIPT_NAME in str(s.get("run", "")) for s in steps)
        if warns and not guards:
            problems.append(f"{path.name}:{job_id}: inline warn step without the divergence guard")
        # Every job that checks tooling out inline at inputs.tooling-ref must
        # run the guard itself, and its sparse set must carry the script.
        if not has_composite:
            for step in steps:
                uses = str(step.get("uses", ""))
                with_ = step.get("with") or {}
                if (
                    uses.startswith("actions/checkout@")
                    and with_.get("path") == ".lgtm-ci-tooling"
                    and "inputs.tooling-ref" in str(with_.get("ref", ""))
                ):
                    if not guards:
                        problems.append(f"{path.name}:{job_id}: inline tooling checkout without the divergence guard")
                    if BOOTSTRAP not in with_.get("sparse-checkout", "").split():
                        problems.append(f"{path.name}:{job_id}: inline tooling checkout omits the guard script from sparse-checkout")
    # Pass-through callers must forward the flag next to tooling-ref.
    forwards = 0
    for job_id, job in (doc.get("jobs") or {}).items():
        with_ = job.get("with") or {}
        if "uses" in job and with_.get("tooling-ref") == "${{ inputs.tooling-ref }}":
            forwards += 1
            if with_.get("tooling-ref-allow-divergence") != ALLOW:
                problems.append(f"{path.name}:{job_id}: forwards tooling-ref without tooling-ref-allow-divergence")
    # A reusable that exposes tooling-ref must run the guard somewhere (via the
    # composite or an inline step) or forward the ref to a reusable that does.
    if guard_steps == 0 and forwards == 0:
        problems.append(f"{path.name}: exposes tooling-ref but wires no divergence guard")

for p in problems:
    print(p)
PY
}

@test "divergence guard: every reusable exposing tooling-ref wires the guard and the escape hatch" {
	require_python_yaml
	run _check "$WORKFLOWS" "${EXEMPT[@]}"
	assert_success
	assert_output ""
}

@test "divergence guard: the check detects a reusable missing the escape hatch" {
	require_python_yaml
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	cat >"$dir/reusable-example.yml" <<'YAML'
name: example
on:
  workflow_call:
    inputs:
      tooling-ref:
        type: string
        default: ""
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          path: .lgtm-ci-tooling
          ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || job.workflow_sha || 'tooling-ref-required' }}
          sparse-checkout: |
            .github/actions/checkout-and-harden
      - uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
        with:
          tooling-ref: x
YAML
	run _check "$dir"
	assert_success
	assert_output --partial "missing tooling-ref-allow-divergence input"
	assert_output --partial "checkout-and-harden lacks workflow-sha"
	assert_output --partial "bootstrap ref must be"
}

@test "divergence guard: the check detects a reusable that exposes tooling-ref but never guards" {
	require_python_yaml
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	cat >"$dir/reusable-unguarded.yml" <<'YAML'
name: unguarded
on:
  workflow_call:
    inputs:
      tooling-ref:
        type: string
        default: ""
      tooling-ref-allow-divergence:
        type: boolean
        default: false
        description: GHES/mirror escape hatch only.
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo no tooling checkout here
YAML
	run _check "$dir"
	assert_success
	assert_output --partial "exposes tooling-ref but wires no divergence guard"
}

@test "divergence guard: the check detects an inline tooling checkout with no guard in its job" {
	require_python_yaml
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	cat >"$dir/reusable-inline.yml" <<'YAML'
name: inline
on:
  workflow_call:
    inputs:
      tooling-ref:
        type: string
        default: ""
      tooling-ref-allow-divergence:
        type: boolean
        default: false
        description: GHES/mirror escape hatch only.
jobs:
  guarded:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          path: .lgtm-ci-tooling
          ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || job.workflow_sha || 'tooling-ref-required' }}
          sparse-checkout: |
            .github/actions/checkout-and-harden
            scripts/ci/
      - env:
          TOOLING_REF_OVERRIDE: ${{ inputs.tooling-ref }}
          WORKFLOW_SHA: ${{ job.workflow_sha }}
          ALLOW_DIVERGENCE: ${{ inputs.tooling-ref-allow-divergence }}
        run: bash .lgtm-ci-tooling/.github/actions/checkout-and-harden/check-tooling-ref-divergence.sh
  unguarded:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          path: .lgtm-ci-tooling
          ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || job.workflow_sha || 'tooling-ref-required' }}
          sparse-checkout: |
            scripts/ci/
      - run: bash .lgtm-ci-tooling/scripts/ci/actions/something.sh
YAML
	run _check "$dir"
	assert_success
	assert_output --partial "reusable-inline.yml:unguarded: inline tooling checkout without the divergence guard"
	assert_output --partial "reusable-inline.yml:unguarded: inline tooling checkout omits the guard script from sparse-checkout"
	refute_output --partial "reusable-inline.yml:guarded:"
}

@test "divergence guard: checkout-and-harden declares the inputs and runs the guard script" {
	for input in tooling-ref-allow-divergence workflow-sha; do
		run grep -E "^  ${input}:" "$ACTION"
		assert_success
	done
	# The checkout rewrites the composite directory to the override ref, so the
	# guard is staged before it and run from outside .lgtm-ci-tooling.
	run grep -F 'src="${GITHUB_ACTION_PATH}/check-tooling-ref-divergence.sh"' "$ACTION"
	assert_success
	run grep -F 'cp "$src" "${RUNNER_TEMP}/check-tooling-ref-divergence.sh"' "$ACTION"
	assert_success
	run grep -F 'bash "${RUNNER_TEMP}/check-tooling-ref-divergence.sh"' "$ACTION"
	assert_success
	# A bootstrap composite that predates the script (GHES fallback to the
	# override ref) must skip the guard, not fail on a missing copy.
	run grep -F "steps.stage-guard.outputs.staged == 'true'" "$ACTION"
	assert_success
	local stage run_line
	stage="$(grep -n 'Stage the tooling-ref divergence guard' "$ACTION" | cut -d: -f1)"
	run_line="$(grep -n 'name: Checkout lgtm-ci tooling' "$ACTION" | cut -d: -f1)"
	[ "$stage" -lt "$run_line" ]
	run grep -F "inputs.tooling-ref-override != ''" "$ACTION"
	assert_success
}

@test "divergence guard: the script exists and is documented" {
	[ -f "${PROJECT_ROOT}/${SCRIPT}" ]
	run grep -F "tooling-ref-allow-divergence" "${PROJECT_ROOT}/docs/workflow-contract.md"
	assert_success
	run grep -F "tooling-ref-allow-divergence" "${PROJECT_ROOT}/docs/reusable-workflows.md"
	assert_success
}
