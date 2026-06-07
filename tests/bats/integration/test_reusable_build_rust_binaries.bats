#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-build-rust-binaries workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-build-rust-binaries.yml"

@test "reusable-build-rust-binaries: declares strict tier via validate-runner-policy" {
	run grep -F 'tier: strict' "$WORKFLOW"
	assert_success
	run grep -F 'validate-runner-policy' "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: egress-preset defaults to rust-release" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "rust-release"'
}

@test "reusable-build-rust-binaries: timeout-minutes defaults to 45" {
	run awk '/^      timeout-minutes:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: 45'
}

@test "reusable-build-rust-binaries: policy before conditional harden-runner" {
	run awk '
		/- name: Validate runner policy/ { policy = 1 }
		policy && /- name: Resolve egress allowlist/ { resolve = 1 }
		resolve && /if: steps\.policy\.outputs\[\x27enforce-egress\x27\] == \x27true\x27/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: uploads artifact with target suffix" {
	run grep -F '${{ matrix.target }}' "$WORKFLOW"
	assert_success
	run grep -F 'SHA256SUMS-${{ matrix.target }}' "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: workflow-level concurrency uses ref name" {
	run awk '/^concurrency:$/,/^jobs:/ { print }' "$WORKFLOW" | grep -F 'rust-binaries-${{ github.ref_name }}'
	assert_success
}
