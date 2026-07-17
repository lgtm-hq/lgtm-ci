#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate test summary markdown for reusable test workflows
#
# Environment variables expected:
#   TESTS_PASSED - Number of tests passed
#   TESTS_FAILED - Number of tests failed
#   TESTS_TOTAL - Total number of tests
#   TESTS_SKIPPED - Number of tests skipped (optional)
#   COVERAGE_ENABLED - Whether coverage was requested (true|false; default false)
#   COVERAGE_PERCENT - Coverage percentage (optional, numeric without %)
#   COVERAGE_THRESHOLD - Coverage threshold (optional)
#   JOB_RESULT - Job result (success/failure)
#   GITHUB_RUN_ID - GitHub Actions run ID
#   GITHUB_REPOSITORY - Repository name
#   GITHUB_SERVER_URL - GitHub server URL
#   TEST_SUITE_NAME - Display name for the test suite (optional)
#   COMMENT_OUTPUT - Path to write the comment body to (optional)

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

# Defaults
TESTS_PASSED="${TESTS_PASSED:-0}"
TESTS_FAILED="${TESTS_FAILED:-0}"
TESTS_TOTAL="${TESTS_TOTAL:-0}"
TESTS_SKIPPED="${TESTS_SKIPPED:-0}"
COVERAGE_ENABLED="${COVERAGE_ENABLED:-false}"
COVERAGE_PERCENT="${COVERAGE_PERCENT:-}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-0}"
JOB_RESULT="${JOB_RESULT:-unknown}"
TEST_SUITE_NAME="${TEST_SUITE_NAME:-Shell Tests}"

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

TESTS_PASSED="$(sanitize_int "$TESTS_PASSED")"
TESTS_FAILED="$(sanitize_int "$TESTS_FAILED")"
TESTS_TOTAL="$(sanitize_int "$TESTS_TOTAL")"
TESTS_SKIPPED="$(sanitize_int "$TESTS_SKIPPED")"
COVERAGE_THRESHOLD="$(sanitize_int "$COVERAGE_THRESHOLD")"
COVERAGE_PROVIDED="true"
if [[ -z "$COVERAGE_PERCENT" || "$COVERAGE_PERCENT" == "N/A" ]]; then
	COVERAGE_PROVIDED="false"
fi
COVERAGE_PERCENT="$(sanitize_decimal "$COVERAGE_PERCENT")"
COVERAGE_DISPLAY="N/A"
if [[ "$COVERAGE_PROVIDED" == "true" ]]; then
	COVERAGE_DISPLAY="${COVERAGE_PERCENT}%"
fi

# Determine basic test status
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	TEST_STATUS_TEXT="❌ Tests failed"
elif [[ "$TESTS_TOTAL" -gt 0 ]]; then
	TEST_STATUS_TEXT="✅ Tests passed"
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

# Calculate pass rate
if [[ "$TESTS_TOTAL" -gt 0 ]]; then
	PASS_RATE=$((TESTS_PASSED * 100 / TESTS_TOTAL))
else
	PASS_RATE=0
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
| **Threshold** | ${COVERAGE_THRESHOLD}% |
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
## 🧪 ${TEST_SUITE_NAME} Report

This PR has been analyzed using **lgtm-ci** - our reusable test workflow.

### 📊 Status: ${STATUS_EMOJI} ${STATUS_TEXT}

**Build:** ${TEST_STATUS_TEXT}${COVERAGE_SECTION}

### 🧪 Test Results

| Metric | Value |
|--------|-------|
| **Total Tests** | ${TESTS_TOTAL} |
| **Passed** | ${TESTS_PASSED} ✅ |
| **Failed** | ${TESTS_FAILED} ${FAILED_EMOJI} |
| **Skipped** | ${TESTS_SKIPPED} |
| **Pass Rate** | ${PASS_RATE}% |
${COVERAGE_TABLE_SECTION}
${BUILD_LINK_BLOCK}

<sub>Generated by ${TEST_SUITE_NAME} workflow</sub>
EOF
)"

if [[ -n "${COMMENT_OUTPUT:-}" ]]; then
	printf '%s\n' "$COMMENT_BODY" >"$COMMENT_OUTPUT"
else
	printf '%s\n' "$COMMENT_BODY"
fi
