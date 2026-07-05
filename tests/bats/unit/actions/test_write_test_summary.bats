#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/write-test-summary.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || exit 1
}

teardown() {
	teardown_temp_dir
}

@test "write-test-summary: writes python summary json for a matrix cell" {
	run env \
		MATRIX_KEY=python-version \
		MATRIX_VALUE=3.12 \
		TESTS_PASSED=10 \
		TESTS_FAILED=2 \
		TESTS_TOTAL=12 \
		COVERAGE_PERCENT=85.50 \
		PASSED=false \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-test-summary.sh"

	assert_success
	assert_file_exists "python-result-3.12/summary.json"
	assert_file_contains "python-result-3.12/summary.json" '"python-version": "3.12"'
	assert_file_contains "python-result-3.12/summary.json" '"tests-passed": "10"'
	assert_file_contains "python-result-3.12/summary.json" '"tests-failed": "2"'
	assert_file_contains "python-result-3.12/summary.json" '"tests-total": "12"'
	assert_file_contains "python-result-3.12/summary.json" '"coverage-percent": "85.50"'
	assert_file_contains "python-result-3.12/summary.json" '"passed": "false"'
}

@test "write-test-summary: writes node summary json for a matrix cell" {
	run env \
		MATRIX_KEY=node-version \
		MATRIX_VALUE=20 \
		TESTS_PASSED=10 \
		TESTS_FAILED=2 \
		TESTS_TOTAL=12 \
		COVERAGE_PERCENT=85.50 \
		PASSED=false \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-test-summary.sh"

	assert_success
	assert_file_exists "node-result-20/summary.json"
	assert_file_contains "node-result-20/summary.json" '"node-version": "20"'
	assert_file_contains "node-result-20/summary.json" '"tests-passed": "10"'
	assert_file_contains "node-result-20/summary.json" '"passed": "false"'
}

@test "write-test-summary: writes rust summary json for a matrix cell" {
	run env \
		MATRIX_KEY=rust-toolchain \
		MATRIX_VALUE=stable \
		TESTS_PASSED=10 \
		TESTS_FAILED=2 \
		TESTS_TOTAL=12 \
		COVERAGE_PERCENT=85.50 \
		PASSED=false \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-test-summary.sh"

	assert_success
	assert_file_exists "rust-result-stable/summary.json"
	assert_file_contains "rust-result-stable/summary.json" '"rust-toolchain": "stable"'
	assert_file_contains "rust-result-stable/summary.json" '"tests-passed": "10"'
	assert_file_contains "rust-result-stable/summary.json" '"passed": "false"'
}

@test "write-test-summary: honors SUMMARY_DIR override" {
	run env \
		MATRIX_KEY=python-version \
		MATRIX_VALUE=3.12 \
		SUMMARY_DIR=custom-dir \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-test-summary.sh"

	assert_success
	assert_file_exists "custom-dir/summary.json"
	assert_file_contains "custom-dir/summary.json" '"python-version": "3.12"'
}

@test "write-test-summary: requires MATRIX_KEY" {
	run env -u MATRIX_KEY MATRIX_VALUE=3.12 \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-test-summary.sh"

	assert_failure
}

@test "write-test-summary: requires MATRIX_VALUE" {
	run env -u MATRIX_VALUE MATRIX_KEY=python-version \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-test-summary.sh"

	assert_failure
}
