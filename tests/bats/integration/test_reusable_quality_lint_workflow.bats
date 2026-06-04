#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-quality-lint egress and timeout inputs

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml"

@test "reusable-quality-lint: egress-policy defaults to block" {
	run awk '/^      egress-policy:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "block"'
}

@test "reusable-quality-lint: egress-preset defaults to quality" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "quality"'
}

@test "reusable-quality-lint: timeout-minutes defaults to 45" {
	run awk '/^      timeout-minutes:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: 45'
}

@test "reusable-quality-lint: quality job uses timeout-minutes input" {
	run awk '
		/^  quality:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  quality:/ { in_job = 0 }
		in_job && /^    timeout-minutes: \$\{\{ inputs\.timeout-minutes \}\}$/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: resolve egress before harden-runner composite" {
	run grep -E '^\s*uses:\s*\./\.github/actions/resolve-egress-allowlist\s*$' "$WORKFLOW"
	assert_success
	run grep -E '^\s*uses:\s*\./\.github/actions/harden-runner\s*$' "$WORKFLOW"
	assert_success
	run grep -F 'egress-preset: ${{ inputs.egress-preset }}' "$WORKFLOW"
	assert_success
	run grep -F "allowed-endpoints: \${{ steps.egress.outputs['allowed-endpoints'] }}" "$WORKFLOW"
	assert_success
	run awk '
		/- name: Checkout repository/ { checkout = 1 }
		checkout && /- name: Resolve egress allowlist/ { resolve = 1 }
		resolve && /- name: Harden runner/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}
