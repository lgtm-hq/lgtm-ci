#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/playwright.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_playwright_json tests - file handling
# =============================================================================

@test "parse_playwright_json: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/playwright.sh"
		parse_playwright_json "/nonexistent/file.json"
		ret=$?
		echo "passed=$TESTS_PASSED failed=$TESTS_FAILED total=$TESTS_TOTAL ret=$ret"
	'
	assert_success
	assert_output "passed=0 failed=0 total=0 ret=1"
}

@test "parse_playwright_json: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/playwright.sh"
		parse_playwright_json ""
		ret=$?
		echo "passed=$TESTS_PASSED ret=$ret"
	'
	assert_success
	assert_output "passed=0 ret=1"
}

# =============================================================================
# parse_playwright_json tests - nested suites format
# =============================================================================

@test "parse_playwright_json: parses nested suites with expected/unexpected status" {
	install_fixture "playwright/parse-playwright-json-parses-nested-suites-with-expected-une.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=3 failed=1 skipped=1 total=5"
}

@test "parse_playwright_json: handles passed/failed status variants" {
	install_fixture "playwright/parse-playwright-json-handles-passed-failed-status-variants.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=2 failed=1 total=3"
}

@test "parse_playwright_json: counts timedOut as failed" {
	install_fixture "playwright/parse-playwright-json-counts-timedout-as-failed.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=1 failed=1 total=2"
}

@test "parse_playwright_json: counts flaky as failed" {
	install_fixture "playwright/parse-playwright-json-counts-flaky-as-failed.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=2 failed=1 total=3"
}

# =============================================================================
# parse_playwright_json tests - stats format
# =============================================================================

@test "parse_playwright_json: falls back to stats object" {
	install_fixture "playwright/parse-playwright-json-falls-back-to-stats-object.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=8 failed=2 skipped=1 total=11"
}

@test "parse_playwright_json: includes flaky in stats failed count" {
	install_fixture "playwright/parse-playwright-json-includes-flaky-in-stats-failed-count.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	# failed = unexpected(1) + flaky(2) = 3
	assert_output "passed=5 failed=3 total=8"
}

# =============================================================================
# parse_playwright_json tests - duration handling
# =============================================================================

@test "parse_playwright_json: converts duration from ms to seconds" {
	install_fixture "playwright/parse-playwright-json-converts-duration-from-ms-to-seconds.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	# 5500ms rounds to 6s (5500 + 500) / 1000 = 6
	assert_output "duration=6"
}

@test "parse_playwright_json: handles small duration" {
	install_fixture "playwright/parse-playwright-json-handles-small-duration.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	# 100ms + 500 = 600, / 1000 = 0 (integer division)
	assert_output "duration=0"
}

@test "parse_playwright_json: handles missing duration" {
	install_fixture "playwright/parse-playwright-json-handles-missing-duration.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "duration=0"
}

# =============================================================================
# parse_playwright_json tests - edge cases
# =============================================================================

@test "parse_playwright_json: handles deeply nested suites" {
	install_fixture "playwright/parse-playwright-json-handles-deeply-nested-suites.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=3 failed=1 total=4"
}

@test "parse_playwright_json: handles empty suites" {
	install_fixture "playwright/parse-playwright-json-handles-empty-suites.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "total=0"
}

@test "parse_playwright_json: handles all passing tests" {
	install_fixture "playwright/parse-playwright-json-handles-all-passing-tests.json" "${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=3 failed=0 total=3"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/playwright.sh: exports parse_playwright_json function" {
	run bash -c 'source "$LIB_DIR/testing/parse/playwright.sh" && bash -c "type parse_playwright_json"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/playwright.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/playwright.sh" && echo "${_LGTM_CI_TESTING_PARSE_PLAYWRIGHT_LOADED}"'
	assert_success
	assert_output "1"
}
