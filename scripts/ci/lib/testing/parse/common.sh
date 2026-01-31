#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Common test result formatting utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#   format_test_summary

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_COMMON_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_COMMON_LOADED=1

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

# Export functions
export -f format_test_summary get_test_status
