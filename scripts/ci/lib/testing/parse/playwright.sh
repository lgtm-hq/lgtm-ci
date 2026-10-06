#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Playwright result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/playwright.sh"
#   parse_playwright_json "results.json"
#
# Fixtures covering every shape this parser accepts (plain, sharded, merged,
# empty, malformed, fractional durations) live in tests/fixtures/playwright/reports/.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_PLAYWRIGHT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_PLAYWRIGHT_LOADED=1

# Reset every output variable to the "no results" state.
_playwright_reset_counts() {
	TESTS_PASSED=0
	TESTS_FAILED=0
	TESTS_SKIPPED=0
	TESTS_TOTAL=0
	TESTS_DURATION="0"
	TESTS_DURATION_MS="0"
}

# Parse Playwright JSON report and extract test counts
# Usage: parse_playwright_json "results.json"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL,
#       TESTS_DURATION (whole seconds), TESTS_DURATION_MS (whole milliseconds)
# Returns: 0 parsed; 1 file missing; 2 file is not valid JSON. Counts are
#          zero on every non-zero return so callers may read them unguarded.
parse_playwright_json() {
	local file="${1:-}"

	_playwright_reset_counts

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	# A truncated or otherwise unparseable report (Playwright killed mid-write)
	# is not an empty one: say so instead of reporting zero tests as a parse.
	if ! jq -e . "$file" >/dev/null 2>&1; then
		return 2
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

	# Duration: Playwright reports stats.duration as fractional milliseconds
	# (e.g. 117018.533). Bash arithmetic is integer-only, so normalize in jq
	# first. Rounding rule: half-up to the nearest whole millisecond
	# (floor(x + 0.5)); missing, non-numeric or negative values become 0.
	TESTS_DURATION_MS=$(jq -r '
		(try (.stats.duration | tonumber) catch 0)
		| if . > 0 then (. + 0.5 | floor) else 0 end
	' "$file" 2>/dev/null || echo "0")
	[[ "$TESTS_DURATION_MS" =~ ^[0-9]+$ ]] || TESTS_DURATION_MS="0"

	# Whole seconds for summaries, again half-up: 1499.5 ms -> 1500 ms -> 2 s.
	TESTS_DURATION=$(((TESTS_DURATION_MS + 500) / 1000))

	return 0
}

# Export functions
export -f _playwright_reset_counts
export -f parse_playwright_json
