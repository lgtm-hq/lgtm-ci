#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: lintro osv-scanner JSON result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/osv.sh"
#   parse_osv_json "osv-results.json"
#
# Input is the lintro JSON report (results[] entries with tool and
# issues_count); the osv_scanner entry carries the vulnerability count.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_OSV_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_OSV_LOADED=1

# Parse a lintro osv-scanner JSON report and extract the finding count
# Usage: parse_osv_json "osv-results.json"
# Sets: OSV_ISSUES (vulnerability count)
# Returns: 0 parsed; 1 file missing; 2 not JSON, not an object or no
#          osv_scanner entry. OSV_ISSUES is 0 on every non-zero return.
parse_osv_json() {
	local file="${1:-}"

	OSV_ISSUES=0
	if [[ ! -f "$file" ]]; then
		return 1
	fi
	local count
	if ! count=$(jq -r '
		if type != "object" then error("not an object") else . end
		| [.results[]? | select(type == "object" and .tool == "osv_scanner")][0]
		| if . == null then error("no osv_scanner result") else (.issues_count // 0) end
	' "$file" 2>/dev/null); then
		return 2
	fi
	if [[ ! "$count" =~ ^[0-9]+$ ]]; then
		return 2
	fi
	OSV_ISSUES="$count"
	return 0
}

# lintro osv-scanner JSON to results.v1 on stdout. Findings are reported
# under counts.failed and counts.total; passed and skipped stay 0.
# Usage: osv_results_v1 "osv-results.json"
# Reads: EXIT_CODE (scanner exit; a non-zero exit with zero findings is a
#        scanner error, status error), RESULTS_ARTIFACTS, RESULTS_SOURCE_VERSION,
#        RESULTS_RUNNER (default run-lintro-audit)
osv_results_v1() {
	local file="${1:-}"
	local parse_status="ok"
	local rc=0

	parse_osv_json "$file" || rc=$?
	case "$rc" in
	0) ;;
	1) parse_status="missing" ;;
	*) parse_status="invalid" ;;
	esac
	# The scanner exits non-zero when it finds something; with no findings
	# that exit means the scan itself failed.
	if [[ "$parse_status" == "ok" && "$OSV_ISSUES" -eq 0 &&
		-n "${EXIT_CODE:-}" && "${EXIT_CODE}" != "0" ]]; then
		parse_status="invalid"
	fi

	TESTS_PASSED=0
	TESTS_FAILED="$OSV_ISSUES"
	TESTS_SKIPPED=0
	TESTS_TOTAL="$OSV_ISSUES"
	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	# A finding is the failure signal; the scanner's own exit code must not
	# turn a clean scan into "failed" (EXIT_CODE is consumed above), and a
	# clean scan is passed, not no-tests.
	local status="passed"
	if [[ "$OSV_ISSUES" -gt 0 ]]; then
		status="failed"
	fi
	RESULTS_TOOL="osv-scanner" RESULTS_RUNNER="${RESULTS_RUNNER:-run-lintro-audit}" \
		RESULTS_PARSE_STATUS="$parse_status" RESULTS_STATUS="$status" EXIT_CODE="" results_v1_build
}

# Export functions
export -f parse_osv_json osv_results_v1
