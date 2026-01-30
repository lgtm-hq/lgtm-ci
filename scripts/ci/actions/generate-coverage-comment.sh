#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate formatted PR comment from code coverage results
#
# Required environment variables:
#   COVERAGE_FILE - Path to coverage summary JSON file
#   FORMAT - Coverage format: istanbul, coverage-py, or auto
#   REPORT_URL - URL to full report (optional)
#   THRESHOLD_LINES - Minimum line coverage percentage
#   THRESHOLD_BRANCHES - Minimum branch coverage percentage
#   THRESHOLD_FUNCTIONS - Minimum function coverage percentage

set -euo pipefail

# Source shared libraries for score_emoji and output helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

if [[ -f "$LIB_DIR/github/format.sh" ]]; then
	# shellcheck source=../lib/github/format.sh
	source "$LIB_DIR/github/format.sh"
fi

if [[ -f "$LIB_DIR/github/output.sh" ]]; then
	# shellcheck source=../lib/github/output.sh
	source "$LIB_DIR/github/output.sh"
fi

: "${COVERAGE_FILE:=coverage/coverage-summary.json}"
: "${FORMAT:=auto}"
: "${REPORT_URL:=}"
: "${THRESHOLD_LINES:=80}"
: "${THRESHOLD_BRANCHES:=70}"
: "${THRESHOLD_FUNCTIONS:=80}"

# Check if coverage file exists
if [[ ! -f "$COVERAGE_FILE" ]]; then
	echo "::warning::Coverage file not found at $COVERAGE_FILE"
	{
		echo "body<<EOF_MISSING"
		echo "## Coverage Report"
		echo ""
		echo "⚠️ No coverage data found"
		echo "EOF_MISSING"
		echo "lines=0"
		echo "branches=0"
		echo "functions=0"
		echo "statements=0"
		echo "passed=false"
	} >>"$GITHUB_OUTPUT"
	exit 0
fi

# Auto-detect format
if [[ "$FORMAT" == "auto" ]]; then
	if jq -e '.total' "$COVERAGE_FILE" >/dev/null 2>&1; then
		FORMAT="istanbul"
	elif jq -e '.totals' "$COVERAGE_FILE" >/dev/null 2>&1; then
		FORMAT="coverage-py"
	else
		FORMAT="istanbul"
	fi
fi

# Extract coverage based on format
case "$FORMAT" in
istanbul)
	LINES=$(jq -r '.total.lines.pct // 0' "$COVERAGE_FILE")
	BRANCHES=$(jq -r '.total.branches.pct // 0' "$COVERAGE_FILE")
	FUNCTIONS=$(jq -r '.total.functions.pct // 0' "$COVERAGE_FILE")
	STATEMENTS=$(jq -r '.total.statements.pct // 0' "$COVERAGE_FILE")
	;;
coverage-py)
	LINES=$(jq -r '.totals.percent_covered // 0' "$COVERAGE_FILE")
	BRANCHES=$(jq -r '.totals.percent_covered_branches // .totals.percent_covered // 0' "$COVERAGE_FILE")
	FUNCTIONS=$LINES # Python coverage doesn't track functions separately
	STATEMENTS=$LINES
	;;
*)
	echo "::error::Unknown coverage format: $FORMAT"
	exit 1
	;;
esac

# Round to integers
LINES=$(printf "%.0f" "$LINES")
BRANCHES=$(printf "%.0f" "$BRANCHES")
FUNCTIONS=$(printf "%.0f" "$FUNCTIONS")
STATEMENTS=$(printf "%.0f" "$STATEMENTS")

{
	echo "lines=$LINES"
	echo "branches=$BRANCHES"
	echo "functions=$FUNCTIONS"
	echo "statements=$STATEMENTS"
} >>"$GITHUB_OUTPUT"

# Check thresholds
PASSED=true
[[ $LINES -lt $THRESHOLD_LINES ]] && PASSED=false
[[ $BRANCHES -lt $THRESHOLD_BRANCHES ]] && PASSED=false
[[ $FUNCTIONS -lt $THRESHOLD_FUNCTIONS ]] && PASSED=false

# Output pass status (grouped with metrics above if needed)
{
	echo "passed=$PASSED"
} >>"$GITHUB_OUTPUT"

# Fallback score_emoji if library not available
if ! declare -f score_emoji &>/dev/null; then
	score_emoji() {
		local score=$1
		local threshold=$2
		local warn=$((threshold - 10))
		((warn < 0)) && warn=0
		if [[ $score -ge $threshold ]]; then
			echo "🟢"
		elif [[ $score -ge $warn ]]; then
			echo "🟡"
		else echo "🔴"; fi
	}
fi

# Generate comment body
BODY="## Coverage Report

| Metric | Coverage | Threshold |
|--------|----------|-----------|
| $(score_emoji "$LINES" "$THRESHOLD_LINES") Lines | **${LINES}%** | ${THRESHOLD_LINES}% |
| $(score_emoji "$BRANCHES" "$THRESHOLD_BRANCHES") Branches | **${BRANCHES}%** | ${THRESHOLD_BRANCHES}% |
| $(score_emoji "$FUNCTIONS" "$THRESHOLD_FUNCTIONS") Functions | **${FUNCTIONS}%** | ${THRESHOLD_FUNCTIONS}% |
| Statements | **${STATEMENTS}%** | - |"

if [[ -n "$REPORT_URL" ]]; then
	BODY="${BODY}

[View Full Report](${REPORT_URL})"
fi

if [[ "$PASSED" == "true" ]]; then
	BODY="${BODY}

✅ Coverage meets all thresholds"
else
	BODY="${BODY}

⚠️ Coverage is below some thresholds"
fi

# Output body using shared helper or fallback
if declare -f set_github_output_multiline &>/dev/null; then
	set_github_output_multiline "body" "$BODY"
else
	EOF_MARKER="EOF_$(date +%s)"
	{
		echo "body<<$EOF_MARKER"
		echo "$BODY"
		echo "$EOF_MARKER"
	} >>"$GITHUB_OUTPUT"
fi
