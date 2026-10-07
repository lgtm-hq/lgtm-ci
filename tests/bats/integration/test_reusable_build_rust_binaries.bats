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

@test "reusable-build-rust-binaries: harden-first with runner-context gate; policy still present" {
	# Harden must be first (pre/main before checkout). Gate with runner context
	# instead of steps.policy outputs (those do not exist at step 1).
	run awk '
		/- name: Harden runner/ { harden = NR; next }
		harden && !gated && /^[[:space:]]+if: runner\.os == .Linux. \|\| runner\.environment == .self-hosted./ { gated = 1 }
		harden && /^[[:space:]]+- name:/ { harden = 0 }
		/- name: Validate runner policy/ { policy = 1 }
		END { exit !(gated && policy) }
	' "$WORKFLOW"
	assert_success
	run egress_tooling_checkout_order_ok "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: uploads artifact with target suffix" {
	run grep -F '${{ matrix.target }}' "$WORKFLOW"
	assert_success
	run grep -F 'SHA256SUMS-${{ matrix.target }}' "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: workflow-level concurrency is namespaced by callee and caller workflow" {
	# `github` in a called workflow is the caller's, so the group carries a
	# stable callee prefix plus the caller repository and workflow (#1076).
	run bash -c "awk '/^concurrency:\$/,/^jobs:/ { print }' '$WORKFLOW' | tr -d '\n' | tr -s ' '"
	assert_success
	assert_output --partial 'lgtm-ci-rust-binaries-${{ github.repository }}-${{ github.workflow }}-${{ github.ref }}-'
	assert_output --partial "\${{ inputs.concurrency-scope || 'default' }}"
	assert_output --partial 'cancel-in-progress: false'
	refute_output --partial 'github.job'
}

@test "reusable-build-rust-binaries: attests release archives not checksum manifests" {
	run awk '/subject-path:/{show=1;next} show&&/^        [a-z]/{exit} show{print}' "$WORKFLOW"
	assert_success
	assert_output --partial '*.tar.gz'
	assert_output --partial '*.zip'
	refute_output --partial 'SHA256SUMS'
}

@test "reusable-build-rust-binaries: installs cross via the annotated script" {
	run grep -F "scripts/ci/release/install-cross.sh" "$WORKFLOW"
	assert_success
	run grep -F "cargo install cross --locked --version 0.2.5" "$WORKFLOW"
	assert_failure
}
