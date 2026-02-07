#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing.sh (aggregator)

load "../../../helpers/common"

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

@test "testing.sh: sources testing/detect.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f detect_test_runner >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "testing.sh: sources testing/parse.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f parse_junit_xml >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "testing.sh: sources testing/coverage.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f check_coverage_threshold >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "testing.sh: sources testing/badge.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f generate_badge_svg >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing.sh"
		source "$LIB_DIR/testing.sh"
		declare -f detect_test_runner >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "testing.sh: sets _LGTM_CI_TESTING_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing.sh" && echo "${_LGTM_CI_TESTING_LOADED}"'
	assert_success
	assert_output "1"
}
