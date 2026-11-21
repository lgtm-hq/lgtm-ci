#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/check-coverage-threshold.sh

load "../../../helpers/common"
load "../../../helpers/coverage_gate_golden"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "check-coverage-threshold: outputs for readable percentages are unchanged (#1692)" {
	local name
	for name in threshold-below threshold-met threshold-zero; do
		run golden_matches "${PROJECT_ROOT}/tests/fixtures/coverage-gate-golden/${name}.txt" coverage_gate_render "$name" "${BATS_TEST_TMPDIR}/${name}"
		assert_success
	done
}

@test "check-coverage-threshold: an unreadable percentage fails, even at threshold 0 (#1692)" {
	local threshold outputs="${BATS_TEST_TMPDIR}/github-output"
	for threshold in 80 0; do
		: >"$outputs"
		run env GITHUB_OUTPUT="$outputs" COVERAGE=invalid THRESHOLD="$threshold" \
			bash "${PROJECT_ROOT}/scripts/ci/actions/check-coverage-threshold.sh"
		assert_failure 1
		assert_output --partial "Invalid COVERAGE value: invalid"
		run grep -c "passed=true" "$outputs"
		assert_output "0"
	done
}

@test "check-coverage-threshold: a threshold or coverage above 100 is refused, never compared (#1692)" {
	local outputs="${BATS_TEST_TMPDIR}/github-output" pair coverage threshold
	for pair in 100:100.5 150:80 100.01:0 80:101; do
		coverage="${pair%%:*}" threshold="${pair##*:}"
		: >"$outputs"
		run env GITHUB_OUTPUT="$outputs" COVERAGE="$coverage" THRESHOLD="$threshold" FAIL_ON_ERROR=false \
			bash "${PROJECT_ROOT}/scripts/ci/actions/check-coverage-threshold.sh"
		assert_failure 1
		assert_output --partial "must be a number from 0 to 100"
		run grep -c "passed=" "$outputs"
		assert_output "0"
	done
	: >"$outputs"
	run env GITHUB_OUTPUT="$outputs" COVERAGE=100 THRESHOLD=100 \
		bash "${PROJECT_ROOT}/scripts/ci/actions/check-coverage-threshold.sh"
	assert_success
	run grep "^passed=" "$outputs"
	assert_output "passed=true"
}
