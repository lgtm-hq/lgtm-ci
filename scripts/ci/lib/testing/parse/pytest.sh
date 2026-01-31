#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pytest result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/pytest.sh"
#   parse_pytest_json "results.json"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_PYTEST_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_PYTEST_LOADED=1

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

# Export functions
export -f parse_pytest_json parse_pytest_coverage
