#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-auto-rerun-on-infra-failure.yml

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-auto-rerun-on-infra-failure.yml"

@test "auto-rerun: requires run-id and run-attempt inputs" {
	local input
	for input in run-id run-attempt; do
		run awk -v name="${input}:" '
			$1 == name { in_input = 1; next }
			in_input && /required: true/ { found = 1; exit }
			in_input && /^      [a-z-]+:/ { in_input = 0 }
			END { exit !found }
		' "$WORKFLOW"
		assert_success
	done
}

@test "auto-rerun: rerun job grants actions write" {
	run grep -F "actions: write" "$WORKFLOW"
	assert_success
	run grep -F "contents: read" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: hardens egress before re-running" {
	run grep -F "harden-runner" "$WORKFLOW"
	assert_success
	run grep -F "checkout-and-harden" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: delegates to the rerun script with no inline shell" {
	run grep -F "rerun-on-infra-failure.sh" "$WORKFLOW"
	assert_success
	run grep -F "RUN_ID: \${{ inputs.run-id }}" "$WORKFLOW"
	assert_success
	run grep -F "RUN_ATTEMPT: \${{ inputs.run-attempt }}" "$WORKFLOW"
	assert_success
	run grep -F "MAX_RERUNS: \${{ inputs.max-reruns }}" "$WORKFLOW"
	assert_success
	run grep -F "SIGNATURES: \${{ inputs.signatures }}" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: tooling checkout includes the rerun script" {
	run grep -F "sparse-checkout" "$WORKFLOW"
	assert_success
	run grep -F "scripts/ci/" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: caps automatic re-runs at one by default" {
	run awk '
		/^      max-reruns:/ { in_input = 1; next }
		in_input && /default: "1"/ { found = 1; exit }
		in_input && /^      [a-z-]+:/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}
