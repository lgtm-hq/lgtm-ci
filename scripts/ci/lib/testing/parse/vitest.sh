#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Vitest result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/vitest.sh"
#   parse_vitest_json "results.json"
#
# Supported JSON reporter shapes:
# - Vitest 3 / Jest aggregate: numPassedTests, numFailedTests, numTotalTests at root
# - Legacy vitest JSON: testResults[].assertionResults[] with status per test

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_VITEST_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_VITEST_LOADED=1

# Parse vitest JSON report and extract test counts
# Usage: parse_vitest_json "results.json"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL, TESTS_DURATION
parse_vitest_json() {
	local file="${1:-}"

	TESTS_PASSED=0
	TESTS_FAILED=0
	TESTS_SKIPPED=0
	TESTS_TOTAL=0
	TESTS_DURATION="0"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	# Vitest 3 / Jest aggregate JSON reporter (root-level num* fields)
	local has_aggregate_counts
	has_aggregate_counts=$(
		jq -r 'if (.numTotalTests | type) == "number" then "yes" else "no" end' "$file" 2>/dev/null || echo "no"
	)
	if [[ "$has_aggregate_counts" == "yes" ]]; then
		TESTS_PASSED=$(jq -r '.numPassedTests // 0' "$file" 2>/dev/null || echo "0")
		TESTS_FAILED=$(jq -r '.numFailedTests // 0' "$file" 2>/dev/null || echo "0")
		TESTS_SKIPPED=$(
			jq -r '(.numPendingTests // 0) + (.numTodoTests // 0)' "$file" 2>/dev/null || echo "0"
		)
		TESTS_TOTAL=$(jq -r '.numTotalTests // 0' "$file" 2>/dev/null || echo "0")
	else
		# Legacy vitest JSON reporter: testResults[].assertionResults[]
		TESTS_PASSED=$(
			jq -r '[.testResults[].assertionResults[]? | select(.status == "passed")] | length' "$file" 2>/dev/null || echo "0"
		)
		TESTS_FAILED=$(
			jq -r '[.testResults[].assertionResults[]? | select(.status == "failed")] | length' "$file" 2>/dev/null || echo "0"
		)
		TESTS_SKIPPED=$(
			jq -r '[.testResults[].assertionResults[]? | select(.status == "pending" or .status == "skipped")] | length' "$file" 2>/dev/null || echo "0"
		)
	fi

	if [[ "${TESTS_TOTAL:-0}" -eq 0 ]]; then
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

# Export functions
export -f parse_vitest_json parse_vitest_coverage
