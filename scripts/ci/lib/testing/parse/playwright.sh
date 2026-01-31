#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Playwright result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/playwright.sh"
#   parse_playwright_json "results.json"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_PLAYWRIGHT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_PLAYWRIGHT_LOADED=1

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
	# Status can be: passed, failed, timedOut, skipped, interrupted, flaky
	# Use recursive descent to handle nested suites
	# Note: flaky tests are counted as failures since they represent unreliable tests
	TESTS_PASSED=$(jq -r '[.. | .tests? // empty | .[] | select(.status == "expected" or .status == "passed")] | length' "$file" 2>/dev/null || echo "0")
	TESTS_FAILED=$(jq -r '[.. | .tests? // empty | .[] | select(.status == "unexpected" or .status == "failed" or .status == "timedOut" or .status == "flaky")] | length' "$file" 2>/dev/null || echo "0")
	TESTS_SKIPPED=$(jq -r '[.. | .tests? // empty | .[] | select(.status == "skipped")] | length' "$file" 2>/dev/null || echo "0")

	# Try simpler format
	if [[ "$TESTS_PASSED" == "0" ]] && [[ "$TESTS_FAILED" == "0" ]]; then
		# Try stats object if present
		if jq -e '.stats' "$file" &>/dev/null; then
			TESTS_PASSED=$(jq -r '.stats.expected // 0' "$file" 2>/dev/null || echo "0")
			TESTS_FAILED=$(jq -r '(.stats.unexpected // 0) + (.stats.flaky // 0)' "$file" 2>/dev/null || echo "0")
			TESTS_SKIPPED=$(jq -r '.stats.skipped // 0' "$file" 2>/dev/null || echo "0")
		fi
	fi

	TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

	# Duration from stats (Playwright always reports in milliseconds)
	TESTS_DURATION=$(jq -r '.stats.duration // 0' "$file" 2>/dev/null || echo "0")
	# Convert milliseconds to seconds with rounding
	if [[ "$TESTS_DURATION" -gt 0 ]]; then
		TESTS_DURATION=$(((TESTS_DURATION + 500) / 1000))
	fi

	return 0
}

# Export functions
export -f parse_playwright_json
