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
		run coverage_gate_render "$name" "${BATS_TEST_TMPDIR}/${name}"
		assert_success
		assert_output "$(cat "${PROJECT_ROOT}/tests/fixtures/coverage-gate-golden/${name}.txt")"
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
