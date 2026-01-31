#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: JUnit XML result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/junit.sh"
#   parse_junit_xml "results.xml"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_JUNIT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_JUNIT_LOADED=1

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

# Export functions
export -f parse_junit_xml
