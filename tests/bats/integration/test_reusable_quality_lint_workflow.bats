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

@test "reusable-quality-lint: hardens via checkout-and-harden composite" {
	run grep -E '^\s*uses:\s*\./\.lgtm-ci-tooling/\.github/actions/checkout-and-harden\s*$' "$WORKFLOW"
	assert_success
	run grep -F 'egress-preset: ${{ inputs.egress-preset }}' "$WORKFLOW"
	assert_success
	run grep -F 'allowed-endpoints: ${{ inputs.allowed-endpoints }}' "$WORKFLOW"
	assert_success
	run awk '
		/- name: Checkout repository/ { checkout = 1 }
		/- name: Checkout lgtm-ci tooling/ { tooling = 1 }
		tooling && /- name: Checkout and harden/ { found = 1 }
		END { exit !(checkout && tooling && found) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: tools is canonical; lintro-tools alias removed" {
	run grep -qE '^      tools:' "$WORKFLOW"
	assert_success
	run grep -qE '^      lintro-tools:' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.lintro-tools' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.tools' "$WORKFLOW"
	assert_success
}
