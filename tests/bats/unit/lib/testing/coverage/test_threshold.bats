#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/coverage/threshold.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# check_coverage_threshold tests
# =============================================================================

@test "check_coverage_threshold: returns 0 when coverage >= threshold" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 85 80 && echo "pass"'
	assert_success
	assert_output "pass"
}

@test "check_coverage_threshold: returns 0 when coverage equals threshold" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 80 80 && echo "pass"'
	assert_success
	assert_output "pass"
}

@test "check_coverage_threshold: returns 1 when coverage < threshold" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 75 80 || echo "fail"'
	assert_success
	assert_output "fail"
}

@test "check_coverage_threshold: handles decimal coverage" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 85.5 85 && echo "pass"'
	assert_success
	assert_output "pass"
}

@test "check_coverage_threshold: handles decimal threshold" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 80 79.9 && echo "pass"'
	assert_success
	assert_output "pass"
}

@test "check_coverage_threshold: returns 0 for zero coverage with zero threshold" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 0 0 && echo "pass"'
	assert_success
	assert_output "pass"
}

@test "check_coverage_threshold: handles 100% coverage" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 100 80 && echo "pass"'
	assert_success
	assert_output "pass"
}

@test "check_coverage_threshold: returns 2 for invalid coverage (negative)" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold -5 80 2>&1'
	assert_failure 2
	assert_output --partial "not a valid"
}

@test "check_coverage_threshold: returns 2 for invalid threshold (negative)" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 80 -5 2>&1'
	assert_failure 2
	assert_output --partial "not a valid"
}

@test "check_coverage_threshold: returns 2 for non-numeric coverage" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold "abc" 80 2>&1'
	assert_failure 2
	assert_output --partial "not a valid"
}

@test "check_coverage_threshold: returns 2 for non-numeric threshold" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold 80 "xyz" 2>&1'
	assert_failure 2
	assert_output --partial "not a valid"
}

@test "check_coverage_threshold: uses default values when empty" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && check_coverage_threshold && echo "pass"'
	assert_success
	assert_output "pass"
}

# =============================================================================
# get_coverage_delta tests
# =============================================================================

@test "get_coverage_delta: returns positive delta" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 85 80'
	assert_success
	assert_output "+5.00"
}

@test "get_coverage_delta: returns negative delta" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 75 80'
	assert_success
	assert_output "-5.00"
}

@test "get_coverage_delta: returns zero delta" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 80 80'
	assert_success
	assert_output "+0.00"
}

@test "get_coverage_delta: handles decimal values" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 85.5 80.25'
	assert_success
	assert_output "+5.25"
}

@test "get_coverage_delta: returns 2 for invalid current value" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta "abc" 80 2>&1'
	assert_failure 2
	assert_output --partial "not a valid"
}

@test "get_coverage_delta: returns 2 for invalid previous value" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 80 "xyz" 2>&1'
	assert_failure 2
	assert_output --partial "not a valid"
}

@test "get_coverage_delta: formats output with two decimal places" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 85.123 80.456'
	assert_success
	# Check format is X.XX (two decimal places)
	[[ "$output" =~ ^[+-][0-9]+\.[0-9]{2}$ ]]
}

@test "get_coverage_delta: handles large delta" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 100 0'
	assert_success
	assert_output "+100.00"
}

@test "get_coverage_delta: handles negative numbers in delta calculation" {
	# This tests that we can calculate delta even if current is lower
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && get_coverage_delta 0 100'
	assert_success
	assert_output "-100.00"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "threshold.sh: exports check_coverage_threshold function" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && bash -c "check_coverage_threshold 85 80 && echo ok"'
	assert_success
	assert_output "ok"
}

@test "threshold.sh: exports get_coverage_delta function" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && bash -c "get_coverage_delta 85 80"'
	assert_success
	assert_output "+5.00"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "threshold.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing/coverage/threshold.sh"
		source "$LIB_DIR/testing/coverage/threshold.sh"
		source "$LIB_DIR/testing/coverage/threshold.sh"
		check_coverage_threshold 85 80 && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "threshold.sh: sets _LGTM_CI_TESTING_COVERAGE_THRESHOLD_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing/coverage/threshold.sh" && echo "${_LGTM_CI_TESTING_COVERAGE_THRESHOLD_LOADED}"'
	assert_success
	assert_output "1"
}
