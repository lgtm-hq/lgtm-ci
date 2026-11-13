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

# jq definitions for counting the tests of a Playwright JSON report. The one
# counting rule for parse_playwright_json and the e2e merge's shard check
# (merge-playwright-reports.sh), so the two cannot count differently (#1474).
#
#   pw_tests          every test object under .suites, at any suite depth.
#                     Only .suites: `config`/`metadata` are not results, and a
#                     merged report keeps only one shard's config. A `tests`
#                     value that is not an array is an error, not zero tests.
#   pw_passed_status  expected, passed
#   pw_failed_status  unexpected, failed, timedOut, flaky (flaky counts as
#                     failed: the test is unreliable)
#   pw_skipped_status skipped
#   pw_counted_status any of the three above
#   pw_count(f)       number of pw_tests whose .status satisfies f
#
# Usage: jq "${PLAYWRIGHT_JQ_DEFS}"' pw_count(pw_passed_status)' report.json
# shellcheck disable=SC2034 # read by sourcing scripts
PLAYWRIGHT_JQ_DEFS='
def pw_tests:
	(.suites // []) | .. | objects | select(has("tests")) | .tests
	| if type == "array" then .[] else error("tests is not an array") end;
def pw_passed_status: . == "expected" or . == "passed";
def pw_failed_status:
	. == "unexpected" or . == "failed" or . == "timedOut" or . == "flaky";
def pw_skipped_status: . == "skipped";
def pw_counted_status: pw_passed_status or pw_failed_status or pw_skipped_status;
def pw_count(f): [pw_tests | select(.status | f)] | length;
'

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
	# `-e true` fails on a zero-byte file (no document) and on bad syntax, but
	# accepts any JSON document, including a bare `null`.
	if ! jq -e 'true' "$file" >/dev/null 2>&1; then
		return 2
	fi

	# Tests under .suites, counted by PLAYWRIGHT_JQ_DEFS (shared with the merge's
	# shard check). A report jq cannot count (e.g. `tests` not an array) counts
	# zero here and falls through to the stats below.
	local counts
	if ! counts=$(jq -r "${PLAYWRIGHT_JQ_DEFS}"'
		"\(pw_count(pw_passed_status)) \(pw_count(pw_failed_status)) \(pw_count(pw_skipped_status))"' \
		"$file" 2>/dev/null) || [[ ! "$counts" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
		counts="0 0 0"
	fi
	read -r TESTS_PASSED TESTS_FAILED TESTS_SKIPPED <<<"$counts"

	# A report without tests in suites (a stats-only summary) falls back to its
	# stats. Only when suites hold no counted test at all: a suite of skipped
	# tests is a real count, and stats must not override it (#1474).
	if [[ "$TESTS_PASSED" == "0" ]] && [[ "$TESTS_FAILED" == "0" ]] && [[ "$TESTS_SKIPPED" == "0" ]]; then
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

# Native Playwright JSON reporter output to results.v1 on stdout.
# Usage: playwright_results_v1 "playwright-results.json"
# Reads: EXIT_CODE, MATRIX_KEY, MATRIX_VALUE, RESULTS_ARTIFACTS,
#        RESULTS_SOURCE_VERSION, RESULTS_RUNNER (default run-playwright-tests)
playwright_results_v1() {
	local report="${1:-}"
	local parse_status="ok"
	local rc=0

	parse_playwright_json "$report" || rc=$?
	case "$rc" in
	0) ;;
	1) parse_status="missing" ;;
	*) parse_status="invalid" ;;
	esac

	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	RESULTS_TOOL="playwright" RESULTS_RUNNER="${RESULTS_RUNNER:-run-playwright-tests}" \
		RESULTS_PARSE_STATUS="$parse_status" results_v1_build
}

export -f playwright_results_v1
