#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/coverage.sh (aggregator)

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# Aggregator loading tests
# =============================================================================

@test "coverage.sh: sources coverage/extract.sh" {
	run bash -c 'source "$LIB_DIR/testing/coverage.sh" && declare -f extract_coverage_percent >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "coverage.sh: sources coverage/merge.sh" {
	run bash -c 'source "$LIB_DIR/testing/coverage.sh" && declare -f merge_lcov_files >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "coverage.sh: sources coverage/threshold.sh" {
	run bash -c 'source "$LIB_DIR/testing/coverage.sh" && declare -f check_coverage_threshold >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "coverage.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing/coverage.sh"
		source "$LIB_DIR/testing/coverage.sh"
		declare -f check_coverage_threshold >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "coverage.sh: sets _LGTM_CI_TESTING_COVERAGE_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing/coverage.sh" && echo "${_LGTM_CI_TESTING_COVERAGE_LOADED}"'
	assert_success
	assert_output "1"
}
