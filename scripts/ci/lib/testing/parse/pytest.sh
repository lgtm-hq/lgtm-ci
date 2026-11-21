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

# The whole-report coverage check (#1692) is extract.sh's; it is loaded here so
# that no caller builds a results.v1 document without it.
# shellcheck source=../coverage/extract.sh
source "$(dirname "${BASH_SOURCE[0]}")/../coverage/extract.sh"

# Parse pytest JSON report and extract test counts
# Usage: parse_pytest_json "results.json"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL, TESTS_DURATION,
#       TESTS_XFAILED, TESTS_XPASSED
parse_pytest_json() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		TESTS_PASSED=0
		TESTS_FAILED=0
		TESTS_SKIPPED=0
		TESTS_TOTAL=0
		TESTS_DURATION="0"
		TESTS_XFAILED=0
		TESTS_XPASSED=0
		return 1
	fi

	# Extract summary values from pytest-json-report format. Its summary holds
	# one key per outcome (passed, failed, error, skipped, xfailed, xpassed;
	# absent when 0) and total = their sum. A test that errors (in setup or
	# teardown, say) is counted under "error", not "failed", so errors are
	# folded into failed here, as junit.sh does for <error> (#1684). xfailed and
	# xpassed are their own counts (#1685), in the total and in none of the
	# others; pytest already reports a strict xpass as failed.
	TESTS_PASSED=$(jq -r '.summary.passed // 0' "$file" 2>/dev/null || echo "0")
	TESTS_FAILED=$(jq -r '(.summary.failed // 0) + (.summary.error // 0)' "$file" 2>/dev/null || echo "0")
	TESTS_SKIPPED=$(jq -r '.summary.skipped // 0' "$file" 2>/dev/null || echo "0")
	TESTS_TOTAL=$(jq -r '.summary.total // 0' "$file" 2>/dev/null || echo "0")
	TESTS_DURATION=$(jq -r '.duration // 0' "$file" 2>/dev/null || echo "0")
	TESTS_XFAILED=$(jq -r '.summary.xfailed // 0' "$file" 2>/dev/null || echo "0")
	TESTS_XPASSED=$(jq -r '.summary.xpassed // 0' "$file" 2>/dev/null || echo "0")

	# If total is 0, try calculating from individual counts
	if [[ "$TESTS_TOTAL" == "0" ]]; then
		TESTS_TOTAL=$(jq -r '[.summary | (.xfailed // 0), (.xpassed // 0)] | add' "$file" 2>/dev/null || echo "0")
		TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED + TESTS_TOTAL))
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

# Internal: mark COVERAGE_LINES invalid when the whole report is unreadable.
# Usage: _pytest_coverage_verdict "coverage.json"
_pytest_coverage_verdict() {
	# The whole report must be readable (#1692): one unreadable metric, not
	# only the ones read here, makes results_v1_build record no coverage and
	# fail, as a gate reading the document would otherwise pass on the rest.
	local verdict=0
	coverage_report_readable "$1" >/dev/null 2>&1 || verdict=$?
	((verdict != 1)) || COVERAGE_LINES="invalid"
}

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
		_pytest_coverage_verdict "$file"
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
		_pytest_coverage_verdict "$file"
		return 0
	fi
	return 1
}

# jq program: the expected failures of a pytest-json-report document as an
# array of {id, reason} in report order (#1685); results_v1_build bounds it.
#
# pytest-json-report 1.5.0 does not serialise pytest's `wasxfail` (the
# marker's reason). Per test it writes `outcome` ("xfailed") and, per stage
# (setup, call, teardown), the stage `outcome` ("skipped" for the stage that
# xfailed), `longrepr` (report.longreprtext: the traceback) and `crash`
# (report.longrepr.reprcrash: path, lineno, message). So the reason read is:
#   - a stage `wasxfail` string, when a conftest hook or a later plugin
#     version adds one;
#   - else the xfailed stage's crash message: for pytest.xfail("...") and
#     xfail(run=False) that is "_pytest.outcomes.XFailed: <reason>" (the
#     prefix is removed), for a marked test that raised it is the exception
#     it raised ("assert 1 == 2", "ValueError: boom");
#   - else "" (no reason recorded).
# A strict xpass is outcome "failed" and is not listed.
# shellcheck disable=SC2016 # jq program, not shell expansion
read -r -d '' _PYTEST_JQ_XFAIL_REASONS <<'JQ' || true
[ (.tests // [])
  | if type == "array" then .[] else empty end
  | objects
  | select(.outcome == "xfailed")
  | . as $test
  | ([.setup, .call, .teardown] | map(objects | select(.outcome == "skipped")) | first) as $stage
  | {id: (if ($test.nodeid | type) == "string" then $test.nodeid else "" end),
     reason: (
       if ($stage.wasxfail | type) == "string" then $stage.wasxfail
       elif ($stage.crash.message | type) == "string" then
         ($stage.crash.message | sub("^_pytest\\.outcomes\\.XFailed: "; ""))
       else "" end)} ]
JQ
export _PYTEST_JQ_XFAIL_REASONS

# jq program: replace the reasons of the list above with the marker reasons a
# pytest JUnit report of the same run gives (#1686). pytest-json-report keeps
# no marker reason, but pytest's junitxml writes it as <skipped
# type="pytest.xfail" message="...">. $junit[0] is junit_xfail_reasons'
# object keyed "<classname>::<name>"; the key of a nodeid is built the way
# pytest's mangle_test_address does it ("a/b.py::C::t[x]" -> "a.b.C::t[x]").
# An id without a JUnit entry keeps its JSON reason, and ids never change.
# shellcheck disable=SC2016 # jq program, not shell expansion
read -r -d '' _PYTEST_JQ_JUNIT_REASONS <<'JQ' || true
def junit_key:
  (index("[")) as $at
  | (if $at == null then [., ""] else [.[:$at], .[$at:]] end) as [$path, $params]
  | ($path | split("::")) as $parts
  | ([$parts[0] | gsub("/"; ".") | sub("\\.py$"; "")] + $parts[1:]) as $names
  | ($names[:-1] | join(".")) as $classname
  | ($names[-1] + $params) as $name
  | if $classname == "" then $name else $classname + "::" + $name end;
($junit[0] // {}) as $reasons
| if ($reasons | type) != "object" then . else
    map(if (.id | type) == "string" and (.id | length) > 0
          and (($reasons[.id | junit_key] // null) | type) == "string"
        then .reason = $reasons[.id | junit_key] else . end)
  end
JQ
export _PYTEST_JQ_JUNIT_REASONS

# Native pytest-json-report (plus optional coverage file) to results.v1 on stdout.
# Usage: pytest_results_v1 "pytest-results.json" ["coverage.json"] ["junit.xml"]
# A pytest JUnit report of the same run, when given, supplies the expected
# failures' marker reasons (#1686); the counts still come from the JSON report.
# Reads: EXIT_CODE, MATRIX_KEY, MATRIX_VALUE, RESULTS_ARTIFACTS,
#        RESULTS_SOURCE_VERSION, RESULTS_RUNNER (default run-pytest)
pytest_results_v1() {
	local report="${1:-}"
	local coverage_file="${2:-}"
	local junit_file="${3:-}"
	local parse_status="ok"

	TESTS_PASSED=0
	TESTS_FAILED=0
	TESTS_SKIPPED=0
	TESTS_TOTAL=0
	TESTS_DURATION_MS=0
	TESTS_XFAILED=""
	TESTS_XPASSED=""
	local list_reasons="false"
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
		if [[ "$TESTS_XFAILED" =~ ^[0-9]{1,9}$ && "$((10#$TESTS_XFAILED))" -gt 0 ]]; then
			list_reasons="true"
		fi
	fi

	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	if [[ -n "$coverage_file" && -f "$coverage_file" ]]; then
		pytest_coverage_metrics "$coverage_file" || true
	fi

	# The reasons reach the builder through a pipe (process substitution), so
	# no temporary file exists to leak on any exit path, signals included,
	# and the list never travels as a command-line argument (#1702).
	if [[ "$list_reasons" == "true" && -n "$junit_file" && -f "$junit_file" ]]; then
		RESULTS_TOOL="pytest" RESULTS_RUNNER="${RESULTS_RUNNER:-run-pytest}" \
			RESULTS_PARSE_STATUS="$parse_status" \
			RESULTS_EXPECTED_FAILURES_FILE=<(jq -c "$_PYTEST_JQ_XFAIL_REASONS" "$report" 2>/dev/null |
				jq -c --slurpfile junit <(junit_xfail_reasons "$junit_file") \
					"$_PYTEST_JQ_JUNIT_REASONS" 2>/dev/null) \
			results_v1_build
	elif [[ "$list_reasons" == "true" ]]; then
		RESULTS_TOOL="pytest" RESULTS_RUNNER="${RESULTS_RUNNER:-run-pytest}" \
			RESULTS_PARSE_STATUS="$parse_status" \
			RESULTS_EXPECTED_FAILURES_FILE=<(jq -c "$_PYTEST_JQ_XFAIL_REASONS" "$report" 2>/dev/null) \
			results_v1_build
	else
		RESULTS_TOOL="pytest" RESULTS_RUNNER="${RESULTS_RUNNER:-run-pytest}" \
			RESULTS_PARSE_STATUS="$parse_status" RESULTS_EXPECTED_FAILURES_FILE="" \
			results_v1_build
	fi
}

export -f _pytest_coverage_verdict pytest_coverage_metrics pytest_results_v1
