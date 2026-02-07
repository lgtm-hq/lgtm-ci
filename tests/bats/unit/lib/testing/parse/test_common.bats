#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/common.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# format_test_summary tests
# =============================================================================

@test "format_test_summary: returns 'No tests found' when total is 0" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_TOTAL=0
		format_test_summary
	'
	assert_success
	assert_output "No tests found"
}

@test "format_test_summary: formats all passed tests" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_PASSED=10
		TESTS_FAILED=0
		TESTS_SKIPPED=0
		TESTS_TOTAL=10
		format_test_summary
	'
	assert_success
	assert_output "10 passed (10 total)"
}

@test "format_test_summary: includes failed count when > 0" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_PASSED=8
		TESTS_FAILED=2
		TESTS_SKIPPED=0
		TESTS_TOTAL=10
		format_test_summary
	'
	assert_success
	assert_output "8 passed, 2 failed (10 total)"
}

@test "format_test_summary: includes skipped count when > 0" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_PASSED=8
		TESTS_FAILED=0
		TESTS_SKIPPED=2
		TESTS_TOTAL=10
		format_test_summary
	'
	assert_success
	assert_output "8 passed, 2 skipped (10 total)"
}

@test "format_test_summary: includes both failed and skipped when > 0" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_PASSED=6
		TESTS_FAILED=2
		TESTS_SKIPPED=2
		TESTS_TOTAL=10
		format_test_summary
	'
	assert_success
	assert_output "6 passed, 2 failed, 2 skipped (10 total)"
}

@test "format_test_summary: uses defaults when variables not set" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		unset TESTS_PASSED TESTS_FAILED TESTS_SKIPPED TESTS_TOTAL
		format_test_summary
	'
	assert_success
	assert_output "No tests found"
}

@test "format_test_summary: handles large numbers" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_PASSED=1234
		TESTS_FAILED=56
		TESTS_SKIPPED=78
		TESTS_TOTAL=1368
		format_test_summary
	'
	assert_success
	assert_output "1234 passed, 56 failed, 78 skipped (1368 total)"
}

# =============================================================================
# get_test_status tests
# =============================================================================

@test "get_test_status: returns 'no-tests' when total is 0" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_TOTAL=0
		TESTS_FAILED=0
		get_test_status
	'
	assert_success
	assert_output "no-tests"
}

@test "get_test_status: returns 'passed' when no failures" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_TOTAL=10
		TESTS_FAILED=0
		get_test_status
	'
	assert_success
	assert_output "passed"
}

@test "get_test_status: returns 'failed' when failures > 0" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_TOTAL=10
		TESTS_FAILED=1
		get_test_status
	'
	assert_success
	assert_output "failed"
}

@test "get_test_status: returns 'failed' with multiple failures" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		TESTS_TOTAL=10
		TESTS_FAILED=5
		get_test_status
	'
	assert_success
	assert_output "failed"
}

@test "get_test_status: uses defaults when variables not set" {
	run bash -c '
		source "$LIB_DIR/testing/parse/common.sh"
		unset TESTS_TOTAL TESTS_FAILED
		get_test_status
	'
	assert_success
	assert_output "no-tests"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/common.sh: exports format_test_summary function" {
	run bash -c 'source "$LIB_DIR/testing/parse/common.sh" && bash -c "type format_test_summary"'
	assert_success
}

@test "testing/parse/common.sh: exports get_test_status function" {
	run bash -c 'source "$LIB_DIR/testing/parse/common.sh" && bash -c "type get_test_status"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/common.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/common.sh" && echo "${_LGTM_CI_TESTING_PARSE_COMMON_LOADED}"'
	assert_success
	assert_output "1"
}
