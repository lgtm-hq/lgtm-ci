#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pytest result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/pytest.sh"
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

# Coverage metrics for results.v1 from the file pytest wrote (coverage.py
# JSON, Cobertura XML or LCOV, per COVERAGE_FORMAT).
# Usage: pytest_coverage_metrics "coverage.json"
# Sets: COVERAGE_LINES, COVERAGE_BRANCHES, COVERAGE_FUNCTIONS; a metric the
#       file does not measure is left empty so the contract omits it.
pytest_coverage_metrics() {
	local file="${1:-}"
	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	[[ -f "$file" ]] || return 1

	if jq -e '.totals.percent_covered' "$file" >/dev/null 2>&1; then
		# coverage.py JSON: percent_covered_branches exists only with --branch.
		COVERAGE_LINES=$(jq -r '.totals.percent_covered' "$file")
		COVERAGE_BRANCHES=$(jq -r '.totals.percent_covered_branches // empty' "$file")
		return 0
	fi
	if declare -f extract_coverage_details >/dev/null 2>&1; then
		extract_coverage_details "$file" || return 1
		# Cobertura carries line-rate/branch-rate only; extract_coverage_details
		# leaves functions at its 0 default, which the contract must not
		# report as a measured 0%.
		if declare -f detect_coverage_format >/dev/null 2>&1 &&
			[[ "$(detect_coverage_format "$file")" == "cobertura" ]]; then
			COVERAGE_FUNCTIONS=""
		fi
		return 0
	fi
	return 1
}

# Native pytest-json-report (plus optional coverage file) to results.v1 on stdout.
# Usage: pytest_results_v1 "pytest-results.json" ["coverage.json"]
# Reads: EXIT_CODE, MATRIX_KEY, MATRIX_VALUE, RESULTS_ARTIFACTS,
#        RESULTS_SOURCE_VERSION, RESULTS_RUNNER (default run-pytest)
pytest_results_v1() {
	local report="${1:-}"
	local coverage_file="${2:-}"
	local parse_status="ok"

	TESTS_PASSED=0
	TESTS_FAILED=0
	TESTS_SKIPPED=0
	TESTS_TOTAL=0
	TESTS_DURATION_MS=0
	if [[ ! -f "$report" ]]; then
		parse_status="missing"
	elif ! jq -e 'true' "$report" >/dev/null 2>&1; then
		parse_status="invalid"
	else
		parse_pytest_json "$report" || true
		# pytest reports seconds; the contract wants whole milliseconds (half-up).
		TESTS_DURATION_MS=$(jq -r '
			(try (.duration | tonumber) catch 0)
			| if . > 0 then (. * 1000 + 0.5 | floor) else 0 end
		' "$report" 2>/dev/null || echo "0")
	fi

	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	if [[ -n "$coverage_file" && -f "$coverage_file" ]]; then
		pytest_coverage_metrics "$coverage_file" || true
	fi

	RESULTS_TOOL="pytest" RESULTS_RUNNER="${RESULTS_RUNNER:-run-pytest}" \
		RESULTS_PARSE_STATUS="$parse_status" results_v1_build
}

export -f pytest_coverage_metrics pytest_results_v1
