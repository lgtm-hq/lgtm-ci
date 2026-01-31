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
	# Scan entire file to handle files with long XML headers/declarations
	local root_element
	root_element=$(grep -m1 -o '<testsuites\|<testsuite' "$file")

	if [[ "$root_element" == "<testsuites" ]]; then
		# First try to extract from the <testsuites> root element itself
		local testsuites_line
		testsuites_line=$(grep '<testsuites' "$file" | head -1)
		TESTS_TOTAL=$(echo "$testsuites_line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
		TESTS_FAILED=$(echo "$testsuites_line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
		TESTS_ERRORS=$(echo "$testsuites_line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
		TESTS_SKIPPED=$(echo "$testsuites_line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')

		# If root element lacks ALL attributes, sum from child <testsuite> elements
		# Only re-aggregate when no values were extracted, to preserve partial data
		if [[ -z "$TESTS_TOTAL" ]] && [[ -z "$TESTS_FAILED" ]] && [[ -z "$TESTS_ERRORS" ]] && [[ -z "$TESTS_SKIPPED" ]]; then
			TESTS_TOTAL=0
			TESTS_FAILED=0
			TESTS_ERRORS=0
			TESTS_SKIPPED=0
			while IFS= read -r line; do
				local t f e s
				t=$(echo "$line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
				f=$(echo "$line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
				e=$(echo "$line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
				s=$(echo "$line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')
				TESTS_TOTAL=$((TESTS_TOTAL + ${t:-0}))
				TESTS_FAILED=$((TESTS_FAILED + ${f:-0}))
				TESTS_ERRORS=$((TESTS_ERRORS + ${e:-0}))
				TESTS_SKIPPED=$((TESTS_SKIPPED + ${s:-0}))
			done < <(grep '<testsuite[^s]' "$file")
		fi
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

	# Combine errors into failures for total failure count, but preserve TESTS_ERRORS
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
