#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-tests.sh summary and parse
#          fallbacks: expected failures and unexpected passes (#1702).

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-tests.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	: >"$GITHUB_OUTPUT"
	: >"$GITHUB_STEP_SUMMARY"
}

teardown() {
	teardown_temp_dir
}

@test "run-tests summary: Expected failures and Unexpected passes rows when above 0 (#1702)" {
	run env STEP=summary RUNNER=pytest TESTS_PASSED=10 TESTS_FAILED=0 TESTS_SKIPPED=1 \
		TESTS_XFAILED=2 TESTS_XPASSED=1 TESTS_TOTAL=14 bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| **Expected failures** | 2 |"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| **Unexpected passes** | 1 ⚠️ |"
}

@test "run-tests summary: no rows when the counts are 0, empty or not counts (#1702)" {
	local value
	for value in 0 "" x 1234567890; do
		: >"$GITHUB_STEP_SUMMARY"
		run env STEP=summary RUNNER=pytest TESTS_PASSED=10 TESTS_TOTAL=10 \
			TESTS_XFAILED="$value" TESTS_XPASSED="$value" bash "$SCRIPT"
		assert_success
		run grep -cE 'Expected failures|Unexpected passes' "$GITHUB_STEP_SUMMARY"
		assert_output "0"
	done
}

@test "run-tests parse: an unknown runner writes 0 for every count output (#1702)" {
	run env STEP=parse RUNNER=unknown-runner WORKING_DIRECTORY="$BATS_TEST_TMPDIR" bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-xfailed=0"
	assert_file_contains "$GITHUB_OUTPUT" "tests-xpassed=0"
}
