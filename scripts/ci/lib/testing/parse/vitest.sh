#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Vitest result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/vitest.sh"
#   parse_vitest_json "results.json"
#
# Supported JSON reporter shape:
# - Vitest 4 aggregate JSON reporter: numPassedTests, numFailedTests,
#   numTotalTests at root (plus numPendingTests / numTodoTests for skipped)

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

	local num_total_type
	num_total_type=$(jq -r '.numTotalTests | type' "$file" 2>/dev/null || echo "null")
	if [[ "$num_total_type" != "number" ]]; then
		return 1
	fi

	TESTS_PASSED=$(jq -r '.numPassedTests // 0' "$file" 2>/dev/null || echo "0")
	TESTS_FAILED=$(jq -r '.numFailedTests // 0' "$file" 2>/dev/null || echo "0")
	TESTS_SKIPPED=$(
		jq -r '(.numPendingTests // 0) + (.numTodoTests // 0)' "$file" 2>/dev/null || echo "0"
	)
	TESTS_TOTAL=$(jq -r '.numTotalTests // 0' "$file" 2>/dev/null || echo "0")

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

# Native vitest JSON reporter (plus optional istanbul coverage-summary.json)
# to results.v1 on stdout.
# Usage: vitest_results_v1 "vitest-results.json" ["coverage/coverage-summary.json"]
# Reads: EXIT_CODE, MATRIX_KEY, MATRIX_VALUE, RESULTS_ARTIFACTS,
#        RESULTS_SOURCE_VERSION, RESULTS_RUNNER (default run-vitest)
vitest_results_v1() {
	local report="${1:-}"
	local coverage_file="${2:-}"
	local parse_status="ok"

	TESTS_DURATION_MS=0
	if [[ ! -f "$report" ]]; then
		parse_status="missing"
		parse_vitest_json "$report" || true
	elif ! parse_vitest_json "$report"; then
		# Present but not the aggregate reporter shape (no numeric numTotalTests).
		parse_status="invalid"
	else
		# startTime/endTime are epoch milliseconds.
		TESTS_DURATION_MS=$(jq -r '
			((.startTime // 0) | tonumber? // 0) as $s
			| ((.endTime // 0) | tonumber? // 0) as $e
			| if $s > 0 and $e >= $s then ($e - $s | floor) else 0 end
		' "$report" 2>/dev/null || echo "0")
	fi

	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	if [[ -n "$coverage_file" && -f "$coverage_file" ]]; then
		# istanbul writes pct "Unknown" when a metric has no entries; the
		# contract builder omits any non-numeric value.
		COVERAGE_LINES=$(jq -r '.total.lines.pct // empty' "$coverage_file" 2>/dev/null || echo "")
		COVERAGE_BRANCHES=$(jq -r '.total.branches.pct // empty' "$coverage_file" 2>/dev/null || echo "")
		COVERAGE_FUNCTIONS=$(jq -r '.total.functions.pct // empty' "$coverage_file" 2>/dev/null || echo "")
	fi

	RESULTS_TOOL="vitest" RESULTS_RUNNER="${RESULTS_RUNNER:-run-vitest}" \
		RESULTS_PARSE_STATUS="$parse_status" results_v1_build
}

export -f vitest_results_v1
