#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: JUnit XML result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/junit.sh"
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
	# Skip XML prolog, DOCTYPE, and comments to find actual root element
	local root_element
	root_element=$(grep -v '^[[:space:]]*<?' "$file" | grep -v '^[[:space:]]*<!' | grep -m1 -o '<testsuites\|<testsuite')

	if [[ "$root_element" == "<testsuites" ]]; then
		# First try to extract from the <testsuites> root element itself
		local testsuites_line
		testsuites_line=$(grep '<testsuites' "$file" | head -1)
		TESTS_TOTAL=$(echo "$testsuites_line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
		TESTS_FAILED=$(echo "$testsuites_line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
		TESTS_ERRORS=$(echo "$testsuites_line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
		TESTS_SKIPPED=$(echo "$testsuites_line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')

		# For each missing attribute, sum from child <testsuite> elements
		# Handle each field independently to preserve partial root data
		local need_total need_failed need_errors need_skipped
		need_total=$([[ -z "$TESTS_TOTAL" ]] && echo 1 || echo 0)
		need_failed=$([[ -z "$TESTS_FAILED" ]] && echo 1 || echo 0)
		need_errors=$([[ -z "$TESTS_ERRORS" ]] && echo 1 || echo 0)
		need_skipped=$([[ -z "$TESTS_SKIPPED" ]] && echo 1 || echo 0)

		if [[ "$need_total" -eq 1 ]] || [[ "$need_failed" -eq 1 ]] || [[ "$need_errors" -eq 1 ]] || [[ "$need_skipped" -eq 1 ]]; then
			# Initialize only the missing fields
			[[ "$need_total" -eq 1 ]] && TESTS_TOTAL=0
			[[ "$need_failed" -eq 1 ]] && TESTS_FAILED=0
			[[ "$need_errors" -eq 1 ]] && TESTS_ERRORS=0
			[[ "$need_skipped" -eq 1 ]] && TESTS_SKIPPED=0

			# Sum from child <testsuite> elements (exclude <testsuites> lines)
			while IFS= read -r line; do
				local t f e s
				t=$(echo "$line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
				f=$(echo "$line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
				e=$(echo "$line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
				s=$(echo "$line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')
				[[ "$need_total" -eq 1 ]] && TESTS_TOTAL=$((TESTS_TOTAL + ${t:-0}))
				[[ "$need_failed" -eq 1 ]] && TESTS_FAILED=$((TESTS_FAILED + ${f:-0}))
				[[ "$need_errors" -eq 1 ]] && TESTS_ERRORS=$((TESTS_ERRORS + ${e:-0}))
				[[ "$need_skipped" -eq 1 ]] && TESTS_SKIPPED=$((TESTS_SKIPPED + ${s:-0}))
			done < <(grep '<testsuite' "$file" | grep -v '<testsuites')
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

# JUnit XML (plus optional LCOV coverage) to results.v1 on stdout.
# Usage: junit_results_v1 "results.xml" ["coverage.lcov"]
# Reads: RESULTS_TOOL (default junit; nextest callers pass cargo-nextest),
#        RESULTS_RUNNER (default run-junit), EXIT_CODE, MATRIX_KEY,
#        MATRIX_VALUE, RESULTS_ARTIFACTS, RESULTS_SOURCE_VERSION
junit_results_v1() {
	local file="${1:-}"
	local coverage_file="${2:-}"
	local parse_status="ok"

	TESTS_DURATION_MS=0
	if [[ ! -f "$file" ]]; then
		parse_status="missing"
		parse_junit_xml "$file" || true
	elif ! grep -q '<testsuite' "$file"; then
		parse_status="invalid"
		parse_junit_xml "/nonexistent/junit.xml" || true
	else
		parse_junit_xml "$file" || true
		# Root element time="<seconds>" when the producer reports one. The
		# prolog and doctype are stripped in place (a one-line report keeps
		# its root on the prolog line), and a report without a time attribute
		# must leave duration at 0 under set -euo pipefail, hence || true.
		local root_time
		root_time=$(sed -e 's/<?[^>]*?>//g' -e 's/<![^>]*>//g' "$file" | tr '\n' ' ' |
			grep -o '<testsuites\?[^>]*' | head -n 1 |
			sed -n 's/.*[[:space:]]time="\([0-9.]*\)".*/\1/p' || true)
		if [[ -n "$root_time" ]]; then
			TESTS_DURATION_MS=$(awk -v t="$root_time" 'BEGIN { printf "%d", (t * 1000) + 0.5 }')
		fi
	fi

	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	if [[ -n "$coverage_file" && -f "$coverage_file" ]] &&
		declare -f extract_coverage_details >/dev/null 2>&1; then
		extract_coverage_details "$coverage_file" || true
	fi

	RESULTS_TOOL="${RESULTS_TOOL:-junit}" RESULTS_RUNNER="${RESULTS_RUNNER:-run-junit}" \
		RESULTS_PARSE_STATUS="$parse_status" results_v1_build
}

export -f junit_results_v1
