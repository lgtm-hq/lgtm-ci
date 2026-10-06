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
# Native reporter output (tests/fixtures/playwright/reports, #804 / #1080)
# =============================================================================

# Run the parser on a fixture and print every output variable plus the return code.
_parse_report() {
	local fixture="$1"
	bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${FIXTURES_DIR}/playwright/reports/${fixture}\"
		ret=\$?
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL ms=\$TESTS_DURATION_MS s=\$TESTS_DURATION ret=\$ret\"
	"
}

@test "parse_playwright_json: real JSON report with passed, failed, flaky and skipped" {
	run _parse_report json-mixed.json
	assert_success
	# flaky counts as failed; 2374.609 ms -> 2375 ms -> 2 s
	assert_output "passed=1 failed=2 skipped=1 total=4 ms=2375 s=2 ret=0"
}

@test "parse_playwright_json: real all-passing JSON report" {
	run _parse_report json-passing.json
	assert_success
	assert_output "passed=1 failed=0 skipped=1 total=2 ms=532 s=1 ret=0"
}

@test "parse_playwright_json: fractional duration is normalized to integer ms before arithmetic" {
	run _parse_report json-fractional-duration.json
	assert_success
	# 117018.533 ms (the #804 report) -> 117019 ms -> 117 s, and no
	# "invalid arithmetic operator" on stderr
	assert_output "passed=1 failed=0 skipped=0 total=1 ms=117019 s=117 ret=0"
	refute_output --partial "arithmetic"
}

@test "parse_playwright_json: rounds half-up at both the ms and the s stage" {
	run _parse_report json-half-millisecond.json
	assert_success
	# 1499.5 ms -> 1500 ms -> (1500 + 500) / 1000 = 2 s
	assert_output "passed=1 failed=0 skipped=0 total=1 ms=1500 s=2 ret=0"
}

@test "parse_playwright_json: empty report (no tests found) parses to zero counts" {
	run _parse_report json-empty.json
	assert_success
	# stats.duration 7.275 ms -> 7 ms -> 0 s
	assert_output "passed=0 failed=0 skipped=0 total=0 ms=7 s=0 ret=0"
}

@test "parse_playwright_json: malformed report returns 2 with zero counts" {
	run _parse_report json-malformed.json
	assert_success
	assert_output "passed=0 failed=0 skipped=0 total=0 ms=0 s=0 ret=2"
}

@test "parse_playwright_json: malformed report is silent on stderr" {
	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${FIXTURES_DIR}/playwright/reports/json-malformed.json\" 2>&1 >/dev/null
		true
	"
	assert_success
	refute_output
}

@test "parse_playwright_json: sharded reports parse per shard" {
	run _parse_report json-shard-1of2.json
	assert_success
	assert_output "passed=0 failed=2 skipped=0 total=2 ms=2373 s=2 ret=0"

	run _parse_report json-shard-2of2.json
	assert_success
	assert_output "passed=1 failed=0 skipped=1 total=2 ms=567 s=1 ret=0"
}

@test "parse_playwright_json: merged report from merge-reports equals the sum of its shards" {
	run _parse_report json-merged.json
	assert_success
	# 3316.22509765625 ms -> 3316 ms -> 3 s
	assert_output "passed=1 failed=2 skipped=1 total=4 ms=3316 s=3 ret=0"
}

@test "parse_playwright_json: HTML report directory with JSON sidecar parses the sidecar" {
	run _parse_report html-sidecar/playwright-results.json
	assert_success
	assert_output "passed=1 failed=0 skipped=1 total=2 ms=532 s=1 ret=0"
	assert_file_exists "${FIXTURES_DIR}/playwright/reports/html-sidecar/playwright-report/index.html"
}

@test "parse_playwright_json: non-numeric duration becomes 0 ms" {
	echo '{"stats":{"expected":1,"duration":"soon"}}' >"${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"ms=\$TESTS_DURATION_MS s=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "ms=0 s=0"
}

@test "parse_playwright_json: numeric string duration is accepted" {
	echo '{"stats":{"expected":1,"duration":"2500.4"}}' >"${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"ms=\$TESTS_DURATION_MS s=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "ms=2500 s=3"
}

@test "parse_playwright_json: negative duration clamps to 0" {
	echo '{"stats":{"expected":1,"duration":-12.5}}' >"${BATS_TEST_TMPDIR}/playwright.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"ms=\$TESTS_DURATION_MS s=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "ms=0 s=0"
}

@test "parse_playwright_json: resets counts from a previous call before a missing file" {
	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${FIXTURES_DIR}/playwright/reports/json-mixed.json\"
		parse_playwright_json /nonexistent.json || true
		echo \"passed=\$TESTS_PASSED total=\$TESTS_TOTAL ms=\$TESTS_DURATION_MS\"
	"
	assert_success
	assert_output "passed=0 total=0 ms=0"
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
