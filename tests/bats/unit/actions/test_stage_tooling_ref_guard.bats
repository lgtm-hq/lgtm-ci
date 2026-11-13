#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for .github/actions/checkout-and-harden/stage-tooling-ref-guard.sh (#1368, #1450)
#
# Each test runs the script the way the composite does, from a copy of the
# action directory, so a directory without the guard script stands in for a
# bootstrap composite that predates it.

load "../../../helpers/common"

ACTION_DIR="${PROJECT_ROOT}/.github/actions/checkout-and-harden"

setup() {
	export GITHUB_ACTION_PATH="${BATS_TEST_TMPDIR}/action"
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner-temp"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	export TOOLING_REF_OVERRIDE="v0.1.0"
	mkdir -p "$GITHUB_ACTION_PATH" "$RUNNER_TEMP"
	: >"$GITHUB_OUTPUT"
	cp "${ACTION_DIR}/stage-tooling-ref-guard.sh" "$GITHUB_ACTION_PATH/"
}

_stage() {
	run bash "${GITHUB_ACTION_PATH}/stage-tooling-ref-guard.sh"
}

@test "stage-tooling-ref-guard: copies the guard to RUNNER_TEMP and reports staged=true" {
	cp "${ACTION_DIR}/check-tooling-ref-divergence.sh" "$GITHUB_ACTION_PATH/"
	_stage
	assert_success
	assert_output ""
	cmp "${ACTION_DIR}/check-tooling-ref-divergence.sh" \
		"${RUNNER_TEMP}/check-tooling-ref-divergence.sh"
	run cat "$GITHUB_OUTPUT"
	assert_output "staged=true"
}

@test "stage-tooling-ref-guard: an absent guard skips with a notice and staged=false" {
	_stage
	assert_success
	assert_output "::notice title=tooling-ref divergence::the bootstrap composite predates the divergence guard; skipping the check for tooling-ref v0.1.0"
	[ ! -e "${RUNNER_TEMP}/check-tooling-ref-divergence.sh" ]
	run cat "$GITHUB_OUTPUT"
	assert_output "staged=false"
}

@test "stage-tooling-ref-guard: a failing cp fails the step without writing an output" {
	cp "${ACTION_DIR}/check-tooling-ref-divergence.sh" "$GITHUB_ACTION_PATH/"
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/no-such-dir"
	_stage
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output ""
}

@test "stage-tooling-ref-guard: the composite runs it from its own directory before the checkout" {
	local action="${ACTION_DIR}/action.yml"
	run grep -F 'run: bash "${GITHUB_ACTION_PATH}/stage-tooling-ref-guard.sh"' "$action"
	assert_success
	run awk '
		/run: bash "\$\{GITHUB_ACTION_PATH\}\/stage-tooling-ref-guard.sh"/ { stage = NR }
		/name: Checkout lgtm-ci tooling/ { if (stage) ok = 1 }
		END { exit !ok }
	' "$action"
	assert_success
}
