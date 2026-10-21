#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-all-checks-gate workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-all-checks-gate.yml"

@test "reusable-all-checks-gate: gate job has the static ruleset name" {
	run awk '
		/^  gate:/ { in_job = 1; next }
		/^  [a-zA-Z0-9_-]+:/ { in_job = 0 }
		in_job && /^    name: "✅ All Checks Passed"$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-all-checks-gate: script default self name matches the job name" {
	run grep -F ': "${SELF_CHECK_NAME:=✅ All Checks Passed}"' \
		"${PROJECT_ROOT}/scripts/ci/actions/all-checks-gate.sh"
	assert_success
}

@test "reusable-all-checks-gate: job permissions are read-only and cover the polled APIs" {
	run awk '
		/^    permissions:/ { in_perm = 1; next }
		in_perm && /^    [a-z]/ { in_perm = 0 }
		in_perm && /^      [a-z-]+: / { print $1 $2 }
	' "$WORKFLOW"
	assert_success
	assert_output "actions:read
checks:read
contents:read
statuses:read"
}

@test "reusable-all-checks-gate: needs no secrets" {
	run grep -E '^    secrets:|secrets\.' "$WORKFLOW"
	assert_failure
}

@test "reusable-all-checks-gate: gates the PR head on pull_request and the queue head on merge_group" {
	run grep -F 'HEAD_SHA: ${{ inputs.head-sha || github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.sha }}' "$WORKFLOW"
	assert_success
}

@test "reusable-all-checks-gate: excludes its own workflow run" {
	run grep -F 'SELF_WORKFLOW_REF: ${{ github.workflow_ref }}' "$WORKFLOW"
	assert_success
	run grep -F 'SELF_RUN_ID: ${{ github.run_id }}' "$WORKFLOW"
	assert_success
}

@test "reusable-all-checks-gate: runs the gate script from the tooling checkout" {
	run grep -F 'run: bash .lgtm-ci-tooling/scripts/ci/actions/all-checks-gate.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-all-checks-gate: hardens the runner before the tooling checkout" {
	run grep -E 'uses:[[:space:]]+step-security/harden-runner@[0-9a-f]{40}' "$WORKFLOW"
	assert_success
	run grep -E '^\s*uses:\s*\./\.lgtm-ci-tooling/\.github/actions/checkout-and-harden\s*$' "$WORKFLOW"
	assert_success
	# No repository checkout: the gate only reads the API.
	run awk '
		/- name: Harden runner/ { harden = NR }
		/- name: Checkout lgtm-ci tooling/ { tooling = NR }
		/- name: Checkout and harden/ { cah = NR }
		/- name: Checkout repository/ { repo = NR }
		END { exit !(harden && harden < tooling && tooling < cah && !repo) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-all-checks-gate: wires every tuning input into the script" {
	for pair in \
		'IGNORE_PATTERN: ${{ inputs.ignore-checks }}' \
		'SETTLE_SECONDS: ${{ inputs.settle-seconds }}' \
		'POLL_INTERVAL: ${{ inputs.poll-interval-seconds }}' \
		'TIMEOUT_MINUTES: ${{ inputs.timeout-minutes }}' \
		'timeout-minutes: ${{ inputs.timeout-minutes }}'; do
		run grep -F "$pair" "$WORKFLOW"
		assert_success
	done
}
