#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate test summary markdown for reusable test workflows
#
# Environment variables expected:
#   TESTS_PASSED - Number of tests passed
#   TESTS_FAILED - Number of tests failed
#   TESTS_TOTAL - Total number of tests
#   TESTS_SKIPPED - Number of tests skipped (optional; digits only, anything
#     else is ignored with a warning). The pass rate is passed / (passed +
#     failed), with "(of N run)" when that is not the total; any rest of the
#     total beyond passed, failed and skipped is shown as "Other" (#1684)
#   TESTS_XFAILED, TESTS_XPASSED - Expected failures and unexpected passes
#     (optional, #1685; digits only, handled as TESTS_SKIPPED). Each has its
#     own row when above 0, and Other shows only what the total holds beyond
#     them; unexpected passes add a line under the table
#   RESULTS_EXPECTED_FAILURES_FILE - A results.v1 expected_failures object
#     (optional, #1685): listed in a collapsed block under the table, test ids
#     and reasons sanitised (docs/comment-sanitize.md)
#   RESULTS_PARSE_STATUS - ok (default) when the counts were parsed; any other
#     value (missing, invalid, error) omits the metrics table (#1371)
#   RESULTS_INCOMPLETE - Reason the run was cut short (optional, #1531): the
#     comment says the results are incomplete instead of showing totals or a
#     coverage percentage
#   COVERAGE_ENABLED - Whether coverage was requested (true|false; default false)
#   COVERAGE_PERCENT - Coverage percentage (optional, numeric without %)
#   COVERAGE_THRESHOLD - Coverage threshold (optional)
#   JOB_RESULT - Job result (success/failure)
#   GITHUB_RUN_ID - GitHub Actions run ID
#   GITHUB_REPOSITORY - Repository name
#   GITHUB_SERVER_URL - GitHub server URL
#   TEST_SUITE_NAME - Display name for the test suite (optional; inserted as
#     sanitised text, as is RESULTS_INCOMPLETE: docs/comment-sanitize.md)
#   COMMENT_OUTPUT - Path to write the comment body to (optional)
#
# Outputs (when GITHUB_OUTPUT is set):
#   history-summary - One-line totals for the comment's run history (#1346)

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

if [[ -f "$LIB_DIR/github/format.sh" ]]; then
	# shellcheck source=../lib/github/format.sh
	source "$LIB_DIR/github/format.sh"
fi

if [[ -f "$LIB_DIR/github/output.sh" ]]; then
	# shellcheck source=../lib/github/output.sh
	source "$LIB_DIR/github/output.sh"
fi

# shellcheck source=../lib/github/comment_sanitize.sh
source "$LIB_DIR/github/comment_sanitize.sh"

# Defaults
TESTS_PASSED="${TESTS_PASSED:-0}"
TESTS_FAILED="${TESTS_FAILED:-0}"
TESTS_TOTAL="${TESTS_TOTAL:-0}"
TESTS_SKIPPED="${TESTS_SKIPPED:-0}"
# tests-skipped (#1684) takes plain digits only: a sign, decimal point, space
# or letter would otherwise be stripped into a plausible wrong number. The
# value is never echoed; the tests it named fall into Other.
if [[ ! "$TESTS_SKIPPED" =~ ^[0-9]+$ ]]; then
	echo "::warning::tests-skipped is not a whole number of tests; it is ignored" >&2
	TESTS_SKIPPED=0
fi
TESTS_XFAILED="${TESTS_XFAILED:-0}"
TESTS_XPASSED="${TESTS_XPASSED:-0}"
# tests-xfailed and tests-xpassed (#1685) follow the tests-skipped rule above.
if [[ ! "$TESTS_XFAILED" =~ ^[0-9]+$ ]]; then
	echo "::warning::tests-xfailed is not a whole number of tests; it is ignored" >&2
	TESTS_XFAILED=0
fi
if [[ ! "$TESTS_XPASSED" =~ ^[0-9]+$ ]]; then
	echo "::warning::tests-xpassed is not a whole number of tests; it is ignored" >&2
	TESTS_XPASSED=0
fi
RESULTS_EXPECTED_FAILURES_FILE="${RESULTS_EXPECTED_FAILURES_FILE:-}"
COVERAGE_ENABLED="${COVERAGE_ENABLED:-false}"
COVERAGE_PERCENT="${COVERAGE_PERCENT:-}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-0}"
JOB_RESULT="${JOB_RESULT:-unknown}"
TEST_SUITE_NAME="${TEST_SUITE_NAME:-Shell Tests}"
RESULTS_PARSE_STATUS="${RESULTS_PARSE_STATUS:-ok}"
RESULTS_INCOMPLETE="${RESULTS_INCOMPLETE:-}"

# Untrusted text (#1676): the suite name is a caller input and the incomplete
# reason comes from a results document a test job wrote. Only the sanitised
# copies are inserted into the comment.
mapfile -d '' _safe_text < <(printf '%s\0' "$TEST_SUITE_NAME" "$RESULTS_INCOMPLETE" | comment_sanitize text --nul)
SUITE_NAME_TEXT="${_safe_text[0]-}"
INCOMPLETE_TEXT="${_safe_text[1]-}"

# Normalize COVERAGE_ENABLED to true|false (GitHub boolean inputs are strings)
case "${COVERAGE_ENABLED,,}" in
true | 1 | yes) COVERAGE_ENABLED="true" ;;
*) COVERAGE_ENABLED="false" ;;
esac

# Normalize numeric values to avoid arithmetic errors under set -euo pipefail
sanitize_int() {
	local value="$1"
	value="${value//[^0-9]/}"
	if [[ -z "$value" ]]; then
		echo "0"
	else
		echo "$value"
	fi
}

sanitize_decimal() {
	local value="$1"
	# Strip non-numeric/dot chars
	value="${value//[^0-9.]/}"
	# Extract first valid decimal pattern (e.g., "1.2.3" -> "1.2", ".." -> "0")
	if [[ "$value" =~ ^([0-9]*\.?[0-9]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		echo "0"
	fi
}

# A count that is not a plain whole number (surrounding spaces aside) is
# unreadable (#1676): no totals are shown, the status is never a pass, and
# the comment names the field.
comment_read_count TESTS_PASSED "passed" "${TESTS_PASSED//[[:space:]]/}"
comment_read_count TESTS_FAILED "failed" "${TESTS_FAILED//[[:space:]]/}"
comment_read_count TESTS_TOTAL "total" "${TESTS_TOTAL//[[:space:]]/}"
comment_read_count TESTS_SKIPPED "skipped" "${TESTS_SKIPPED//[[:space:]]/}"
comment_read_count TESTS_XFAILED "xfailed" "$TESTS_XFAILED"
comment_read_count TESTS_XPASSED "xpassed" "$TESTS_XPASSED"
COUNTS_UNREADABLE=${#COMMENT_UNREADABLE[@]}
COVERAGE_THRESHOLD="$(sanitize_int "$COVERAGE_THRESHOLD")"
COVERAGE_PROVIDED="true"
# "n/a" (lowercase) is the coverage-on-empty=not-applicable policy (#1373):
# no percent sign, no threshold verdict.
COVERAGE_NA="false"
if [[ "$COVERAGE_PERCENT" == "n/a" ]]; then
	COVERAGE_NA="true"
	COVERAGE_PERCENT=""
fi
if [[ -z "$COVERAGE_PERCENT" || "$COVERAGE_PERCENT" == "N/A" ]]; then
	COVERAGE_PROVIDED="false"
fi
COVERAGE_UNREADABLE="false"
if [[ "$COVERAGE_PROVIDED" == "true" ]]; then
	# A percentage that is not a plain number is unreadable, not 0% (#1676).
	comment_read_decimal COVERAGE_PERCENT "coverage" "${COVERAGE_PERCENT//[[:space:]]/}"
	if ((${#COMMENT_UNREADABLE[@]} > COUNTS_UNREADABLE)); then
		COVERAGE_PROVIDED="false"
		COVERAGE_UNREADABLE="true"
	elif ! awk -v p="$COVERAGE_PERCENT" 'BEGIN { exit !(p <= 100) }'; then
		# A number above 100 is no percentage: unreadable, never "Target met"
		# (#1692).
		echo "::warning::The report's coverage value is not a number; the comment says so" >&2
		COMMENT_UNREADABLE+=("coverage")
		COVERAGE_PROVIDED="false"
		COVERAGE_UNREADABLE="true"
	fi
fi
COVERAGE_PERCENT="$(sanitize_decimal "$COVERAGE_PERCENT")"
COVERAGE_DISPLAY="N/A"
if [[ "$COVERAGE_NA" == "true" ]]; then
	COVERAGE_DISPLAY="n/a"
fi
if [[ "$COVERAGE_PROVIDED" == "true" ]]; then
	COVERAGE_DISPLAY="${COVERAGE_PERCENT}%"
fi
if [[ "$COVERAGE_UNREADABLE" == "true" ]]; then
	COVERAGE_DISPLAY="unreadable"
fi
# #1531: a cut-short run has no trustworthy percentage, even a partial one.
if [[ -n "$RESULTS_INCOMPLETE" ]]; then
	COVERAGE_PROVIDED="false"
	COVERAGE_NA="false"
	COVERAGE_DISPLAY="incomplete"
fi

# comment_read_count (above) leaves every count in plain decimal with at most
# nine digits (#1684, #1676): no later test reads 08 as octal, the comment
# shows 8, and the sums below cannot overflow. A longer or malformed count is
# unreadable there, which shows no totals at all.
COUNTS_BOUNDED="true"

# Expected failures and unexpected passes that do not fit in the total
# (#1702): passed + failed + skipped + xfailed + xpassed above total cannot be
# shown as rows that add up. The caller's total, passed, failed and skipped
# stay as given; the two new counts are ignored with one warning that names
# the inputs (never the values), and the rest of the total shows as Other,
# as an ignored tests-skipped does.
if ((COUNTS_UNREADABLE == 0 && TESTS_XFAILED + TESTS_XPASSED > 0)) &&
	((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED + TESTS_XFAILED + TESTS_XPASSED > TESTS_TOTAL)); then
	echo "::warning::tests-xfailed and tests-xpassed add up to more than tests-total leaves after passed, failed and skipped; they are ignored" >&2
	TESTS_XFAILED=0
	TESTS_XPASSED=0
fi

# Counts are only trustworthy when the parser produced them (#1371). A parser
# that ran and found nothing on a green job is "no tests", not a pass. A
# cut-short run (#1531) counted only part of its tests.
COUNTS_AVAILABLE="true"
if [[ "$RESULTS_PARSE_STATUS" != "ok" || -n "$RESULTS_INCOMPLETE" ]] || ((COUNTS_UNREADABLE > 0)); then
	COUNTS_AVAILABLE="false"
fi
NO_TESTS="false"
if [[ "$COUNTS_AVAILABLE" == "true" && "$TESTS_TOTAL" -eq 0 &&
	"$TESTS_FAILED" -eq 0 && "$JOB_RESULT" == "success" ]]; then
	NO_TESTS="true"
fi

# Determine basic test status
if ((COUNTS_UNREADABLE > 0)); then
	TEST_STATUS_TEXT="⚠️ Test counts unreadable"
elif [[ "$TESTS_FAILED" -gt 0 ]]; then
	TEST_STATUS_TEXT="❌ Tests failed"
elif [[ -n "$RESULTS_INCOMPLETE" ]]; then
	TEST_STATUS_TEXT="⚠️ Test counts incomplete"
elif [[ "$TESTS_TOTAL" -gt 0 ]]; then
	TEST_STATUS_TEXT="✅ Tests passed"
elif [[ "$NO_TESTS" == "true" ]]; then
	TEST_STATUS_TEXT="⚠️ No tests ran"
elif [[ "$COUNTS_AVAILABLE" != "true" ]]; then
	TEST_STATUS_TEXT="⚠️ Test counts unavailable"
elif [[ "$JOB_RESULT" == "success" ]]; then
	TEST_STATUS_TEXT="✅ Tests passed"
else
	TEST_STATUS_TEXT="⚠️ Tests unknown"
fi

# Coverage status using shared library if available (only when coverage was requested)
COVERAGE_STATUS="Coverage unavailable"
COVERAGE_EMOJI="⚠️"
COVERAGE_BELOW_THRESHOLD="false"
if [[ "$COVERAGE_ENABLED" == "true" ]]; then
	if [[ "$COVERAGE_PROVIDED" == "true" ]]; then
		# Normalize coverage: strip decimals for comparison, defaulting to 0 if empty
		COVERAGE_NUMERIC="$(sanitize_int "${COVERAGE_PERCENT%.*}")"
		if [[ "$COVERAGE_THRESHOLD" -gt 0 ]]; then
			# Use score_emoji from shared library if available
			if declare -f score_emoji &>/dev/null; then
				COVERAGE_EMOJI=$(score_emoji "$COVERAGE_NUMERIC" "$COVERAGE_THRESHOLD")
			else
				# Fallback emoji logic
				if [[ "$COVERAGE_NUMERIC" -ge "$COVERAGE_THRESHOLD" ]]; then
					COVERAGE_EMOJI="✅"
				else
					COVERAGE_EMOJI="⚠️"
				fi
			fi

			if [[ "$COVERAGE_NUMERIC" -ge "$COVERAGE_THRESHOLD" ]]; then
				COVERAGE_STATUS="Target met (>=${COVERAGE_THRESHOLD}%)"
			else
				COVERAGE_STATUS="Below target (<${COVERAGE_THRESHOLD}%)"
				COVERAGE_BELOW_THRESHOLD="true"
			fi
		else
			COVERAGE_STATUS="Coverage recorded"
			COVERAGE_EMOJI="ℹ️"
		fi
	elif [[ -n "$RESULTS_INCOMPLETE" ]]; then
		COVERAGE_STATUS="No percentage published: ${INCOMPLETE_TEXT}"
	elif [[ "$COVERAGE_NA" == "true" ]]; then
		COVERAGE_STATUS="Not applicable: no instrumented lines"
		COVERAGE_EMOJI="ℹ️"
	elif [[ "$TESTS_FAILED" -gt 0 ]]; then
		COVERAGE_STATUS="Unable to retrieve coverage: coverage collection was skipped because tests failed."
	else
		COVERAGE_STATUS="Unable to retrieve coverage: coverage report was not generated."
	fi
fi

# Determine overall status based on JOB_RESULT first, then tests/coverage
# JOB_RESULT may be "failure" due to coverage threshold even when tests pass
if [[ "$JOB_RESULT" == "cancelled" ]]; then
	STATUS_EMOJI="⏭️"
	STATUS_TEXT="CANCELLED"
elif [[ "$JOB_RESULT" == "skipped" ]]; then
	STATUS_EMOJI="⏭️"
	STATUS_TEXT="SKIPPED"
elif [[ "$JOB_RESULT" == "neutral" ]]; then
	STATUS_EMOJI="⏭️"
	STATUS_TEXT="NEUTRAL"
elif [[ "$JOB_RESULT" == "failure" && "$TESTS_FAILED" -eq 0 && "$COVERAGE_BELOW_THRESHOLD" == "true" ]]; then
	STATUS_EMOJI="⚠️"
	STATUS_TEXT="$COVERAGE_STATUS"
elif [[ "$JOB_RESULT" == "failure" ]] || [[ "$TESTS_FAILED" -gt 0 ]]; then
	STATUS_EMOJI="❌"
	STATUS_TEXT="FAILED"
elif [[ "$NO_TESTS" == "true" ]]; then
	STATUS_EMOJI="⚠️"
	STATUS_TEXT="NO TESTS"
elif [[ "$COUNTS_AVAILABLE" != "true" ]]; then
	# A green job whose counts could not be parsed is not a verified pass.
	STATUS_EMOJI="⚠️"
	STATUS_TEXT="NO COUNTS"
elif [[ "$TESTS_TOTAL" -gt 0 ]] && [[ "$TESTS_FAILED" -eq 0 ]]; then
	STATUS_EMOJI="✅"
	STATUS_TEXT="PASSED"
elif [[ "$JOB_RESULT" == "success" ]] && [[ "$TESTS_FAILED" -eq 0 ]]; then
	STATUS_EMOJI="✅"
	STATUS_TEXT="PASSED"
else
	STATUS_EMOJI="⚠️"
	STATUS_TEXT="UNKNOWN"
fi

# Build and commit metadata are best-effort when running outside GitHub Actions.
BUILD_URL=""
if declare -f get_github_actions_run_url &>/dev/null; then
	BUILD_URL=$(get_github_actions_run_url || true)
fi
COMMIT_LINE="- **Commit:** unknown"
if declare -f format_github_commit_line &>/dev/null; then
	COMMIT_LINE=$(format_github_commit_line)
fi
BUILD_LINK_BLOCK=""
if [[ -n "$BUILD_URL" ]]; then
	BUILD_LINK_BLOCK="

---

[View full build details](${BUILD_URL})"
fi

# Compute failed emoji based on numeric check (not string non-empty)
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	FAILED_EMOJI="❌"
else
	FAILED_EMOJI=""
fi

# Calculate pass rate over the tests that passed or failed (#1684); Total
# Tests stays the caller's total. When the two differ the rate names its
# denominator, so 2 passed out of 1000 reads "100% (of 2 run)".
TESTS_RAN=0
PASS_RATE=0
TESTS_OTHER=0
if [[ "$COUNTS_BOUNDED" == "true" ]]; then
	TESTS_RAN=$((TESTS_PASSED + TESTS_FAILED))
	if [[ "$TESTS_RAN" -gt 0 ]]; then
		PASS_RATE=$((TESTS_PASSED * 100 / TESTS_RAN))
	fi
	# Tests the total counts that are neither passed, failed, skipped, an
	# expected failure nor an unexpected pass (#1685). Never negative.
	TESTS_OTHER=$((TESTS_TOTAL - TESTS_RAN - TESTS_SKIPPED - TESTS_XFAILED - TESTS_XPASSED))
	if [[ "$TESTS_OTHER" -lt 0 ]]; then
		TESTS_OTHER=0
	fi
fi
PASS_RATE_DISPLAY="${PASS_RATE}%"
if [[ "$TESTS_RAN" -ne "$TESTS_TOTAL" ]]; then
	PASS_RATE_DISPLAY="${PASS_RATE}% (of ${TESTS_RAN} run)"
fi

# Expected failures with their reasons (#1685), from a results.v1 document.
# Test ids and reasons are untrusted: each goes through the sanitiser, ids as
# code spans and reasons as text. The list stays within the schema's 50
# entries even when the file does not, and within a size budget (#1702):
# sanitising expands text (`<` becomes `&lt;`, `@a` gains an entity), and a
# body over GitHub's limit (262,144 bytes) is replaced by a notice with no
# result (#1705). So the comment shows at most XFAIL_SHOW_CHARS of each
# id and reason (the document keeps 500), and stops adding lines once the
# rendered list would pass XFAIL_BUDGET_BYTES, measured after sanitising;
# every entry not shown is counted in "and N more". The table, the status
# and the closing </details> are never cut.
XFAIL_LIST=""
XFAIL_MAX_TESTS=50
XFAIL_SHOW_CHARS=200
XFAIL_BUDGET_BYTES=20000
# Byte length of $1, through wc: bytes are the upper bound of the characters
# GitHub counts, and changing LC_ALL inside a function crashed bash 5.3 now
# and then (#1702).
_xfail_bytes() {
	printf '%s' "$1" | wc -c | tr -d ' '
}
if [[ -n "$RESULTS_EXPECTED_FAILURES_FILE" && -f "$RESULTS_EXPECTED_FAILURES_FILE" ]]; then
	mapfile -d '' XFAIL_IDS < <(jq -j --argjson max "$XFAIL_MAX_TESTS" '
		(.tests // [])[:$max][]
		| (.id | if type == "string" then gsub("\u0000"; "") else "" end) + "\u0000"' \
		"$RESULTS_EXPECTED_FAILURES_FILE" 2>/dev/null | comment_sanitize code --nul --max "$XFAIL_SHOW_CHARS")
	mapfile -d '' XFAIL_REASONS < <(jq -j --argjson max "$XFAIL_MAX_TESTS" '
		(.tests // [])[:$max][]
		| (.reason | if type == "string" then gsub("\u0000"; "") else "" end) + "\u0000"' \
		"$RESULTS_EXPECTED_FAILURES_FILE" 2>/dev/null | comment_sanitize text --nul --max "$XFAIL_SHOW_CHARS")
	XFAIL_LISTED=${#XFAIL_IDS[@]}
	comment_read_count XFAIL_OMITTED "expected_failures.omitted" \
		"$(jq -r --argjson max "$XFAIL_MAX_TESTS" '(.omitted // 0) + ([((.tests // []) | length) - $max, 0] | max)' \
			"$RESULTS_EXPECTED_FAILURES_FILE" 2>/dev/null)"
	if ((XFAIL_LISTED > 0 || XFAIL_OMITTED > 0)); then
		XFAIL_LIST="<details>
<summary>Expected failures and their reasons</summary>
"
		XFAIL_USED=$(_xfail_bytes "$XFAIL_LIST")
		XFAIL_SHOWN=0
		for ((i = 0; i < XFAIL_LISTED; i++)); do
			XFAIL_LINE="- ${XFAIL_IDS[i]}"
			if [[ -n "${XFAIL_REASONS[i]-}" ]]; then
				XFAIL_LINE+=": ${XFAIL_REASONS[i]}"
			fi
			XFAIL_LINE_BYTES=$(_xfail_bytes "$XFAIL_LINE")
			if ((XFAIL_USED + XFAIL_LINE_BYTES + 1 > XFAIL_BUDGET_BYTES)); then
				break
			fi
			XFAIL_LIST+=$'\n'"$XFAIL_LINE"
			XFAIL_USED=$((XFAIL_USED + XFAIL_LINE_BYTES + 1))
			XFAIL_SHOWN=$((XFAIL_SHOWN + 1))
		done
		XFAIL_MORE=$((XFAIL_OMITTED + XFAIL_LISTED - XFAIL_SHOWN))
		if ((XFAIL_MORE > 0)); then
			XFAIL_LIST+=$'\n'"- and ${XFAIL_MORE} more"
		fi
		# A matrix aggregate lists the same test (same id and reason) from
		# several legs once, so the list can hold fewer entries than the
		# Expected failures count (#1702).
		if ((XFAIL_LISTED + XFAIL_OMITTED < TESTS_XFAILED)); then
			XFAIL_LIST+=$'\n\n'"The same test failing as expected on several matrix legs is listed once."
		fi
		XFAIL_LIST+=$'\n\n'"</details>"
	fi
fi

COVERAGE_THRESHOLD_DISPLAY="${COVERAGE_THRESHOLD}%"
if [[ "$COVERAGE_NA" == "true" ]]; then
	COVERAGE_THRESHOLD_DISPLAY="n/a"
fi

# Metrics table: omitted without parsed counts; no Pass Rate row without tests.
if [[ -n "$RESULTS_INCOMPLETE" ]]; then
	RESULTS_SECTION="No totals shown: ${INCOMPLETE_TEXT} (see the job log)"
elif [[ "$COUNTS_AVAILABLE" != "true" ]]; then
	RESULTS_SECTION="No test counts were parsed for this run (see the job log)"
else
	XFAIL_ROWS=""
	if [[ "$TESTS_XFAILED" -gt 0 ]]; then
		XFAIL_ROWS+="
| **Expected failures** | ${TESTS_XFAILED} |"
	fi
	if [[ "$TESTS_XPASSED" -gt 0 ]]; then
		XFAIL_ROWS+="
| **Unexpected passes** | ${TESTS_XPASSED} ⚠️ |"
	fi
	OTHER_ROW=""
	if [[ "$TESTS_OTHER" -gt 0 ]]; then
		OTHER_ROW="
| **Other** | ${TESTS_OTHER} |"
	fi
	PASS_RATE_ROW=""
	# No rate beside the NO TESTS status (a total of 0), as before.
	if [[ "$TESTS_RAN" -gt 0 && "$NO_TESTS" != "true" ]]; then
		PASS_RATE_ROW="
| **Pass Rate** | ${PASS_RATE_DISPLAY} |"
	fi
	RESULTS_SECTION="$(
		cat <<EOF
| Metric | Value |
|--------|-------|
| **Total Tests** | ${TESTS_TOTAL} |
| **Passed** | ${TESTS_PASSED} ✅ |
| **Failed** | ${TESTS_FAILED} ${FAILED_EMOJI} |
| **Skipped** | ${TESTS_SKIPPED} |${XFAIL_ROWS}${OTHER_ROW}${PASS_RATE_ROW}
EOF
	)"
	if [[ "$TESTS_XPASSED" -eq 1 ]]; then
		RESULTS_SECTION+=$'\n\n'"⚠️ 1 test marked as an expected failure passed: remove the marker from it."
	elif [[ "$TESTS_XPASSED" -gt 1 ]]; then
		RESULTS_SECTION+=$'\n\n'"⚠️ ${TESTS_XPASSED} tests marked as expected failures passed: remove the marker from them."
	fi
	if [[ -n "$XFAIL_LIST" ]]; then
		RESULTS_SECTION+=$'\n\n'"$XFAIL_LIST"
	fi
fi
if ((${#COMMENT_UNREADABLE[@]} > 0)); then
	RESULTS_SECTION+=$'\n\n'"$(comment_unreadable_lines)"
fi

COVERAGE_SECTION=""
if [[ "$COVERAGE_ENABLED" == "true" ]]; then
	COVERAGE_SECTION="$(
		cat <<EOF


**Coverage:** ${COVERAGE_EMOJI} ${COVERAGE_DISPLAY}

**Status:** ${COVERAGE_STATUS}
EOF
	)"
	COVERAGE_TABLE_SECTION="$(
		cat <<EOF

### 📊 Code Coverage

| Metric | Value |
|--------|-------|
| **Line Coverage** | ${COVERAGE_DISPLAY} ${COVERAGE_EMOJI} |
| **Threshold** | ${COVERAGE_THRESHOLD_DISPLAY} |
| **Status** | ${COVERAGE_STATUS} |

### 📋 Coverage Details
- **Generated:** $(date -u +%Y-%m-%d)
${COMMIT_LINE}
EOF
	)"
else
	# Soft guard for direct callers that pass a percent without opting in
	if [[ "$COVERAGE_PROVIDED" == "true" ]]; then
		msg="COVERAGE_PERCENT is set but COVERAGE_ENABLED=false; coverage sections omitted. Pass coverage-enabled: true to include them."
		if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
			echo "::warning::${msg}"
		else
			echo "WARNING: ${msg}" >&2
		fi
	fi
	COVERAGE_TABLE_SECTION="$(
		cat <<EOF

### 📋 Run Details
- **Generated:** $(date -u +%Y-%m-%d)
${COMMIT_LINE}
EOF
	)"
fi

# Generate comment in py-lintro style
COMMENT_BODY="$(
	cat <<EOF
## 🧪 ${SUITE_NAME_TEXT} Report

This PR has been analyzed using **lgtm-ci** - our reusable test workflow.

### 📊 Status: ${STATUS_EMOJI} ${STATUS_TEXT}

**Build:** ${TEST_STATUS_TEXT}${COVERAGE_SECTION}

### 🧪 Test Results

${RESULTS_SECTION}
${COVERAGE_TABLE_SECTION}
${BUILD_LINK_BLOCK}

<sub>Generated by ${SUITE_NAME_TEXT} workflow</sub>
EOF
)"

# Totals line shown on this run's entry once the comment archives it (#1346).
if [[ -n "$RESULTS_INCOMPLETE" ]]; then
	HISTORY_SUMMARY="incomplete"
elif [[ "$COUNTS_AVAILABLE" != "true" ]]; then
	HISTORY_SUMMARY="no counts"
elif [[ "$NO_TESTS" == "true" ]]; then
	HISTORY_SUMMARY="0 tests"
else
	HISTORY_SUMMARY="${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_SKIPPED" -gt 0 ]]; then
		HISTORY_SUMMARY+=", ${TESTS_SKIPPED} skipped"
	fi
	if [[ "$TESTS_XFAILED" -eq 1 ]]; then
		HISTORY_SUMMARY+=", 1 expected failure"
	elif [[ "$TESTS_XFAILED" -gt 1 ]]; then
		HISTORY_SUMMARY+=", ${TESTS_XFAILED} expected failures"
	fi
	if [[ "$TESTS_XPASSED" -eq 1 ]]; then
		HISTORY_SUMMARY+=", 1 unexpected pass"
	elif [[ "$TESTS_XPASSED" -gt 1 ]]; then
		HISTORY_SUMMARY+=", ${TESTS_XPASSED} unexpected passes"
	fi
	if [[ "$TESTS_OTHER" -gt 0 ]]; then
		HISTORY_SUMMARY+=", ${TESTS_OTHER} other"
	fi
fi
if [[ "$COVERAGE_ENABLED" == "true" && "$COVERAGE_PROVIDED" == "true" ]]; then
	HISTORY_SUMMARY+=" · ${COVERAGE_DISPLAY} cov"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "history-summary=${HISTORY_SUMMARY}" >>"$GITHUB_OUTPUT"
fi

if [[ -n "${COMMENT_OUTPUT:-}" ]]; then
	printf '%s\n' "$COMMENT_BODY" >"$COMMENT_OUTPUT"
else
	printf '%s\n' "$COMMENT_BODY"
fi
