#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/write-python-summary.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || exit 1
}

teardown() {
	teardown_temp_dir
}

@test "write-python-summary: writes summary json for a matrix cell" {
	run env \
		PYTHON_VERSION=3.12 \
		TESTS_PASSED=10 \
		TESTS_FAILED=2 \
		TESTS_TOTAL=12 \
		COVERAGE_PERCENT=85.50 \
		PASSED=false \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-python-summary.sh"

	assert_success
	assert_file_exists "python-result-3.12/summary.json"
	assert_file_contains "python-result-3.12/summary.json" '"python-version": "3.12"'
	assert_file_contains "python-result-3.12/summary.json" '"tests-passed": "10"'
	assert_file_contains "python-result-3.12/summary.json" '"tests-failed": "2"'
	assert_file_contains "python-result-3.12/summary.json" '"tests-total": "12"'
	assert_file_contains "python-result-3.12/summary.json" '"coverage-percent": "85.50"'
	assert_file_contains "python-result-3.12/summary.json" '"passed": "false"'
}

@test "write-python-summary: requires PYTHON_VERSION" {
	run env -u PYTHON_VERSION \
		bash "${PROJECT_ROOT}/scripts/ci/actions/write-python-summary.sh"

	assert_failure
}
