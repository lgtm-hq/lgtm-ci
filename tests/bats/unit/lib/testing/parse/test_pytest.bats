#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/pytest.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_pytest_json tests - file handling
# =============================================================================

@test "parse_pytest_json: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/pytest.sh"
		parse_pytest_json "/nonexistent/file.json"
		ret=$?
		echo "passed=$TESTS_PASSED failed=$TESTS_FAILED total=$TESTS_TOTAL ret=$ret"
	'
	assert_success
	assert_output "passed=0 failed=0 total=0 ret=1"
}

@test "parse_pytest_json: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/pytest.sh"
		parse_pytest_json ""
		ret=$?
		echo "passed=$TESTS_PASSED ret=$ret"
	'
	assert_success
	assert_output "passed=0 ret=1"
}

# =============================================================================
# parse_pytest_json tests - pytest-json-report format
# =============================================================================

@test "parse_pytest_json: parses standard pytest-json-report format" {
	install_fixture "pytest/standard-report.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL duration=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "passed=10 failed=2 skipped=1 total=13 duration=5.25"
}

@test "parse_pytest_json: handles all passing tests" {
	install_fixture "pytest/all-passing.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=25 failed=0 total=25"
}

@test "parse_pytest_json: calculates total when not provided" {
	install_fixture "pytest/no-total.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "total=10"
}

@test "parse_pytest_json: handles missing fields with defaults" {
	install_fixture "pytest/missing-fields.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED\"
	"
	assert_success
	assert_output "passed=5 failed=0 skipped=0"
}

@test "parse_pytest_json: handles empty summary" {
	install_fixture "pytest/empty-summary.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=0 total=0"
}

@test "parse_pytest_json: counts errors as failed; xfailed and xpassed are not in passed, failed or skipped (#1684)" {
	# Summary keys as pytest-json-report 1.5.0 writes them: one per outcome,
	# total = their sum (its README example).
	install_fixture "pytest/all-outcomes.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=2 failed=5 skipped=1 total=10"
}

@test "parse_pytest_json: a summary without total sums every outcome (#1684)" {
	install_fixture "pytest/outcomes-no-total.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=4 failed=1 skipped=1 total=9"
}

# =============================================================================
# parse_pytest_coverage tests - file handling
# =============================================================================

@test "parse_pytest_coverage: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/pytest.sh"
		parse_pytest_coverage "/nonexistent/coverage.json"
		ret=$?
		echo "percent=$COVERAGE_PERCENT lines=$COVERAGE_LINES ret=$ret"
	'
	assert_success
	assert_output "percent=0 lines=0 ret=1"
}

# =============================================================================
# parse_pytest_coverage tests - coverage.py format
# =============================================================================

@test "parse_pytest_coverage: parses coverage.py JSON format" {
	install_fixture "pytest/coverage-standard.json" "${BATS_TEST_TMPDIR}/coverage.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"percent=\$COVERAGE_PERCENT lines=\$COVERAGE_LINES branches=\$COVERAGE_BRANCHES\"
	"
	assert_success
	assert_line --partial "lines=171"
	assert_line --partial "branches=42"
}

@test "parse_pytest_coverage: handles 100% coverage" {
	install_fixture "pytest/coverage-100.json" "${BATS_TEST_TMPDIR}/coverage.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"percent=\$COVERAGE_PERCENT\"
	"
	assert_success
	assert_line --partial "percent=100"
}

@test "parse_pytest_coverage: handles 0% coverage" {
	install_fixture "pytest/coverage-0.json" "${BATS_TEST_TMPDIR}/coverage.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"percent=\$COVERAGE_PERCENT lines=\$COVERAGE_LINES\"
	"
	assert_success
	assert_output "percent=0 lines=0"
}

@test "parse_pytest_coverage: handles missing branch coverage" {
	install_fixture "pytest/coverage-no-branches.json" "${BATS_TEST_TMPDIR}/coverage.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"branches=\$COVERAGE_BRANCHES\"
	"
	assert_success
	assert_output "branches=0"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/pytest.sh: exports parse_pytest_json function" {
	run bash -c 'source "$LIB_DIR/testing/parse/pytest.sh" && bash -c "type parse_pytest_json"'
	assert_success
}

@test "testing/parse/pytest.sh: exports parse_pytest_coverage function" {
	run bash -c 'source "$LIB_DIR/testing/parse/pytest.sh" && bash -c "type parse_pytest_coverage"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/pytest.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/pytest.sh" && echo "${_LGTM_CI_TESTING_PARSE_PYTEST_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Expected failures and unexpected passes (#1685)
# =============================================================================

@test "parse_pytest_json: sets TESTS_XFAILED and TESTS_XPASSED from the summary (#1685)" {
	install_fixture "pytest/all-outcomes.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"xfailed=\$TESTS_XFAILED xpassed=\$TESTS_XPASSED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "xfailed=1 xpassed=1 total=10"
}

@test "parse_pytest_json: a summary without xfailed or xpassed counts 0; a missing file resets them (#1685)" {
	install_fixture "pytest/standard-report.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"xfailed=\$TESTS_XFAILED xpassed=\$TESTS_XPASSED\"
		TESTS_XFAILED=9 TESTS_XPASSED=9
		parse_pytest_json /nonexistent.json || echo \"xfailed=\$TESTS_XFAILED xpassed=\$TESTS_XPASSED\"
	"
	assert_success
	assert_output "$(printf '%s\n' 'xfailed=0 xpassed=0' 'xfailed=0 xpassed=0')"
}

@test "pytest_results_v1: strict xpass stays failed, hostile and long reasons are kept bounded and raw (#1685)" {
	install_fixture "pytest/xfail-outcomes.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing.sh\"
		pytest_results_v1 \"${BATS_TEST_TMPDIR}/pytest.json\" | jq -c '[.counts.failed, .counts.xfailed, .counts.xpassed, ([.expected_failures.tests[].reason | length] | max), .expected_failures.tests[1].reason]'
	"
	assert_success
	assert_output '[1,5,1,500,"@org/team #1 <img src=x> [x](javascript:y) <!-- lgtm-ci:history:start -->"]'
}

@test "pytest_results_v1: lists at most 50 expected failures and counts the rest (#1685)" {
	install_fixture "pytest/xfail-over-cap.json" "${BATS_TEST_TMPDIR}/pytest.json"

	run bash -c "
		source \"\$LIB_DIR/testing.sh\"
		pytest_results_v1 \"${BATS_TEST_TMPDIR}/pytest.json\" | jq -c '[(.expected_failures.tests | length), .expected_failures.omitted, .expected_failures.tests[0]]'
	"
	assert_success
	assert_output '[50,10,{"id":"tests/test_x.py::test_known_00","reason":"known bug 0"}]'
}

@test "pytest_results_v1: leaves no temporary reasons file behind (#1685)" {
	install_fixture "pytest/xfail-outcomes.json" "${BATS_TEST_TMPDIR}/pytest.json"
	mkdir -p "${BATS_TEST_TMPDIR}/tmp"

	run bash -c "
		source \"\$LIB_DIR/testing.sh\"
		TMPDIR=\"${BATS_TEST_TMPDIR}/tmp\" pytest_results_v1 \"${BATS_TEST_TMPDIR}/pytest.json\" >/dev/null
		ls -A \"${BATS_TEST_TMPDIR}/tmp\" | wc -l | tr -d ' '
	"
	assert_success
	assert_output "0"
}
