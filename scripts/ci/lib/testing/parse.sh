#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Test result parsing utilities for various test runners
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/parse.sh"
#   parse_pytest_json "results.json"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_LOADED=1

# =============================================================================
# Pytest result parsing
# =============================================================================

# Parse pytest JSON report and extract test counts
# Usage: parse_pytest_json "results.json"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL, TESTS_DURATION
parse_pytest_json() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		TESTS_PASSED=0
		TESTS_FAILED=0
		TESTS_SKIPPED=0
		TESTS_TOTAL=0
		TESTS_DURATION="0"
		return 1
	fi

	# Extract summary values from pytest-json-report format
	TESTS_PASSED=$(jq -r '.summary.passed // 0' "$file" 2>/dev/null || echo "0")
	TESTS_FAILED=$(jq -r '.summary.failed // 0' "$file" 2>/dev/null || echo "0")
	TESTS_SKIPPED=$(jq -r '.summary.skipped // 0' "$file" 2>/dev/null || echo "0")
	TESTS_TOTAL=$(jq -r '.summary.total // 0' "$file" 2>/dev/null || echo "0")
	TESTS_DURATION=$(jq -r '.duration // 0' "$file" 2>/dev/null || echo "0")

	# If total is 0, try calculating from individual counts
	if [[ "$TESTS_TOTAL" == "0" ]]; then
		TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
	fi

	return 0
}

# Parse pytest coverage JSON and extract coverage percentage
# Usage: parse_pytest_coverage "coverage.json"
# Sets: COVERAGE_PERCENT, COVERAGE_LINES, COVERAGE_BRANCHES
parse_pytest_coverage() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		COVERAGE_PERCENT="0"
		COVERAGE_LINES="0"
		COVERAGE_BRANCHES="0"
		return 1
	fi

	# coverage.py JSON format
	COVERAGE_PERCENT=$(jq -r '.totals.percent_covered // 0' "$file" 2>/dev/null || echo "0")
	COVERAGE_LINES=$(jq -r '.totals.covered_lines // 0' "$file" 2>/dev/null || echo "0")
	COVERAGE_BRANCHES=$(jq -r '.totals.covered_branches // 0' "$file" 2>/dev/null || echo "0")

	# Round to 2 decimal places
	if command -v bc &>/dev/null; then
		COVERAGE_PERCENT=$(echo "scale=2; $COVERAGE_PERCENT / 1" | bc 2>/dev/null || echo "$COVERAGE_PERCENT")
	fi

	return 0
}

# =============================================================================
# Vitest result parsing
# =============================================================================

# Parse vitest JSON report and extract test counts
# Usage: parse_vitest_json "results.json"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL, TESTS_DURATION
parse_vitest_json() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		TESTS_PASSED=0
		TESTS_FAILED=0
		TESTS_SKIPPED=0
		TESTS_TOTAL=0
		TESTS_DURATION="0"
		return 1
	fi

	# Vitest JSON reporter format
	TESTS_PASSED=$(jq -r '[.testResults[].assertionResults[] | select(.status == "passed")] | length' "$file" 2>/dev/null || echo "0")
	TESTS_FAILED=$(jq -r '[.testResults[].assertionResults[] | select(.status == "failed")] | length' "$file" 2>/dev/null || echo "0")
	TESTS_SKIPPED=$(jq -r '[.testResults[].assertionResults[] | select(.status == "pending" or .status == "skipped")] | length' "$file" 2>/dev/null || echo "0")

	# Try alternative format (vitest built-in json reporter)
	if [[ "$TESTS_PASSED" == "0" ]] && [[ "$TESTS_FAILED" == "0" ]]; then
		TESTS_PASSED=$(jq -r '.numPassedTests // 0' "$file" 2>/dev/null || echo "0")
		TESTS_FAILED=$(jq -r '.numFailedTests // 0' "$file" 2>/dev/null || echo "0")
		TESTS_SKIPPED=$(jq -r '.numPendingTests // 0' "$file" 2>/dev/null || echo "0")
		TESTS_TOTAL=$(jq -r '.numTotalTests // 0' "$file" 2>/dev/null || echo "0")
	fi

	if [[ "$TESTS_TOTAL" == "0" ]] || [[ -z "$TESTS_TOTAL" ]]; then
		TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
	fi

	# Duration in milliseconds
	local start_time end_time
	start_time=$(jq -r '.startTime // 0' "$file" 2>/dev/null || echo "0")
	end_time=$(jq -r '.endTime // .startTime // 0' "$file" 2>/dev/null || echo "0")
	if [[ "$start_time" != "0" ]] && [[ "$end_time" != "0" ]]; then
		TESTS_DURATION=$(((end_time - start_time) / 1000))
	else
		TESTS_DURATION="0"
	fi

	return 0
}

# Parse vitest coverage JSON (istanbul format) and extract coverage percentage
# Usage: parse_vitest_coverage "coverage-summary.json"
# Sets: COVERAGE_PERCENT, COVERAGE_LINES, COVERAGE_BRANCHES, COVERAGE_FUNCTIONS
parse_vitest_coverage() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		COVERAGE_PERCENT="0"
		COVERAGE_LINES="0"
		COVERAGE_BRANCHES="0"
		COVERAGE_FUNCTIONS="0"
		return 1
	fi

	# Istanbul coverage-summary.json format
	COVERAGE_LINES=$(jq -r '.total.lines.pct // 0' "$file" 2>/dev/null || echo "0")
	COVERAGE_BRANCHES=$(jq -r '.total.branches.pct // 0' "$file" 2>/dev/null || echo "0")
	COVERAGE_FUNCTIONS=$(jq -r '.total.functions.pct // 0' "$file" 2>/dev/null || echo "0")

	# Use lines coverage as the primary percentage
	COVERAGE_PERCENT="$COVERAGE_LINES"

	return 0
}

# =============================================================================
# Playwright result parsing
# =============================================================================

# Parse Playwright JSON report and extract test counts
# Usage: parse_playwright_json "results.json"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL, TESTS_DURATION
parse_playwright_json() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		TESTS_PASSED=0
		TESTS_FAILED=0
		TESTS_SKIPPED=0
		TESTS_TOTAL=0
		TESTS_DURATION="0"
		return 1
	fi

	# Playwright JSON reporter format
	# Status can be: passed, failed, timedOut, skipped, interrupted
	# Use recursive descent to handle nested suites
	TESTS_PASSED=$(jq -r '[.. | .tests? // empty | .[] | select(.status == "expected" or .status == "passed")] | length' "$file" 2>/dev/null || echo "0")
	TESTS_FAILED=$(jq -r '[.. | .tests? // empty | .[] | select(.status == "unexpected" or .status == "failed" or .status == "timedOut")] | length' "$file" 2>/dev/null || echo "0")
	TESTS_SKIPPED=$(jq -r '[.. | .tests? // empty | .[] | select(.status == "skipped")] | length' "$file" 2>/dev/null || echo "0")

	# Try simpler format
	if [[ "$TESTS_PASSED" == "0" ]] && [[ "$TESTS_FAILED" == "0" ]]; then
		# Try stats object if present
		if jq -e '.stats' "$file" &>/dev/null; then
			TESTS_PASSED=$(jq -r '.stats.expected // 0' "$file" 2>/dev/null || echo "0")
			TESTS_FAILED=$(jq -r '.stats.unexpected // 0' "$file" 2>/dev/null || echo "0")
			TESTS_SKIPPED=$(jq -r '.stats.skipped // 0' "$file" 2>/dev/null || echo "0")
		fi
	fi

	TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

	# Duration from stats
	TESTS_DURATION=$(jq -r '.stats.duration // 0' "$file" 2>/dev/null || echo "0")
	# Convert milliseconds to seconds
	if [[ "$TESTS_DURATION" -gt 1000 ]]; then
		TESTS_DURATION=$((TESTS_DURATION / 1000))
	fi

	return 0
}

# =============================================================================
# JUnit XML parsing (common format)
# =============================================================================

# Parse JUnit XML report and extract test counts
# Usage: parse_junit_xml "results.xml"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL, TESTS_ERRORS
parse_junit_xml() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		TESTS_PASSED=0
		TESTS_FAILED=0
		TESTS_SKIPPED=0
		TESTS_TOTAL=0
		TESTS_ERRORS=0
		return 1
	fi

	# Extract from testsuite or testsuites root element
	local root_element
	root_element=$(head -10 "$file" | grep -o '<testsuites\|<testsuite' | head -1)

	if [[ "$root_element" == "<testsuites" ]]; then
		TESTS_TOTAL=$(sed -n 's/.*tests="\([0-9]*\)".*/\1/p' "$file" | head -1)
		TESTS_FAILED=$(sed -n 's/.*failures="\([0-9]*\)".*/\1/p' "$file" | head -1)
		TESTS_ERRORS=$(sed -n 's/.*errors="\([0-9]*\)".*/\1/p' "$file" | head -1)
		TESTS_SKIPPED=$(sed -n 's/.*skipped="\([0-9]*\)".*/\1/p' "$file" | head -1)
	else
		# Single testsuite element - extract from first testsuite tag
		local testsuite_line
		testsuite_line=$(grep '<testsuite' "$file" | head -1)
		TESTS_TOTAL=$(echo "$testsuite_line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
		TESTS_FAILED=$(echo "$testsuite_line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
		TESTS_ERRORS=$(echo "$testsuite_line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
		TESTS_SKIPPED=$(echo "$testsuite_line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')
	fi

	# Ensure values are set
	TESTS_TOTAL="${TESTS_TOTAL:-0}"
	TESTS_FAILED="${TESTS_FAILED:-0}"
	TESTS_ERRORS="${TESTS_ERRORS:-0}"
	TESTS_SKIPPED="${TESTS_SKIPPED:-0}"

	# Combine errors and failures
	TESTS_FAILED=$((TESTS_FAILED + TESTS_ERRORS))
	TESTS_PASSED=$((TESTS_TOTAL - TESTS_FAILED - TESTS_SKIPPED))

	# Ensure passed is not negative
	if [[ "$TESTS_PASSED" -lt 0 ]]; then
		TESTS_PASSED=0
	fi

	return 0
}

# =============================================================================
# Generic result formatting
# =============================================================================

# Format test results as a summary string
# Usage: format_test_summary
# Requires: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL set
format_test_summary() {
	local passed="${TESTS_PASSED:-0}"
	local failed="${TESTS_FAILED:-0}"
	local skipped="${TESTS_SKIPPED:-0}"
	local total="${TESTS_TOTAL:-0}"

	if [[ "$total" -eq 0 ]]; then
		echo "No tests found"
		return
	fi

	local summary="${passed} passed"
	if [[ "$failed" -gt 0 ]]; then
		summary+=", ${failed} failed"
	fi
	if [[ "$skipped" -gt 0 ]]; then
		summary+=", ${skipped} skipped"
	fi
	summary+=" (${total} total)"

	echo "$summary"
}

# Determine overall test status
# Usage: get_test_status
# Returns: passed|failed|no-tests
get_test_status() {
	local failed="${TESTS_FAILED:-0}"
	local total="${TESTS_TOTAL:-0}"

	if [[ "$total" -eq 0 ]]; then
		echo "no-tests"
	elif [[ "$failed" -gt 0 ]]; then
		echo "failed"
	else
		echo "passed"
	fi
}

# =============================================================================
# Export functions
# =============================================================================
export -f parse_pytest_json parse_pytest_coverage
export -f parse_vitest_json parse_vitest_coverage
export -f parse_playwright_json
export -f parse_junit_xml
export -f format_test_summary get_test_status
