#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse.sh (aggregator)

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

@test "parse.sh: sources parse/common.sh" {
	run bash -c 'source "$LIB_DIR/testing/parse.sh" && declare -f format_test_summary >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "parse.sh: sources parse/pytest.sh" {
	run bash -c 'source "$LIB_DIR/testing/parse.sh" && declare -f parse_pytest_json >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "parse.sh: sources parse/vitest.sh" {
	run bash -c 'source "$LIB_DIR/testing/parse.sh" && declare -f parse_vitest_json >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "parse.sh: sources parse/junit.sh" {
	run bash -c 'source "$LIB_DIR/testing/parse.sh" && declare -f parse_junit_xml >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "parse.sh: sources parse/playwright.sh" {
	run bash -c 'source "$LIB_DIR/testing/parse.sh" && declare -f parse_playwright_json >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "parse.sh: sources parse/lighthouse.sh" {
	run bash -c 'source "$LIB_DIR/testing/parse.sh" && declare -f parse_lighthouse_json >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "parse.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing/parse.sh"
		source "$LIB_DIR/testing/parse.sh"
		declare -f parse_junit_xml >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "parse.sh: sets _LGTM_CI_TESTING_PARSE_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing/parse.sh" && echo "${_LGTM_CI_TESTING_PARSE_LOADED}"'
	assert_success
	assert_output "1"
}
