#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate formatted PR comment from Lighthouse CI results
#
# Required environment variables:
#   RESULTS_PATH - Path to Lighthouse results JSON file or directory
#   REPORT_URL - URL to full report (optional)
#   THRESHOLD_PERFORMANCE - Minimum performance score
#   THRESHOLD_ACCESSIBILITY - Minimum accessibility score
#   THRESHOLD_BEST_PRACTICES - Minimum best practices score
#   THRESHOLD_SEO - Minimum SEO score

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

: "${RESULTS_PATH:?RESULTS_PATH is required}"
: "${REPORT_URL:=}"
: "${THRESHOLD_PERFORMANCE:=80}"
: "${THRESHOLD_ACCESSIBILITY:=90}"
: "${THRESHOLD_BEST_PRACTICES:=80}"
: "${THRESHOLD_SEO:=80}"

# Find the results file
# Sort for deterministic selection when directory contains multiple JSON files
if [[ -d "$RESULTS_PATH" ]]; then
	RESULTS_FILE=$(find "$RESULTS_PATH" -name "*.json" -type f | sort | head -1)
else
	RESULTS_FILE="$RESULTS_PATH"
fi

if [[ ! -f "$RESULTS_FILE" ]]; then
	echo "::error::Lighthouse results not found at $RESULTS_PATH"
	exit 1
fi

# Extract scores (multiply by 100 for percentage)
PERF=$(jq -r '.categories.performance.score // 0 | . * 100 | floor' "$RESULTS_FILE")
A11Y=$(jq -r '.categories.accessibility.score // 0 | . * 100 | floor' "$RESULTS_FILE")
BP=$(jq -r '.categories["best-practices"].score // 0 | . * 100 | floor' "$RESULTS_FILE")
SEO=$(jq -r '.categories.seo.score // 0 | . * 100 | floor' "$RESULTS_FILE")

# Check thresholds
PASSED=true
[[ $PERF -lt $THRESHOLD_PERFORMANCE ]] && PASSED=false
[[ $A11Y -lt $THRESHOLD_ACCESSIBILITY ]] && PASSED=false
[[ $BP -lt $THRESHOLD_BEST_PRACTICES ]] && PASSED=false
[[ $SEO -lt $THRESHOLD_SEO ]] && PASSED=false

{
	echo "performance=$PERF"
	echo "accessibility=$A11Y"
	echo "best-practices=$BP"
	echo "seo=$SEO"
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
BODY="## Lighthouse Results

| Category | Score | Threshold |
|----------|-------|-----------|
| $(score_emoji "$PERF" "$THRESHOLD_PERFORMANCE") Performance | **${PERF}** | ${THRESHOLD_PERFORMANCE} |
| $(score_emoji "$A11Y" "$THRESHOLD_ACCESSIBILITY") Accessibility | **${A11Y}** | ${THRESHOLD_ACCESSIBILITY} |
| $(score_emoji "$BP" "$THRESHOLD_BEST_PRACTICES") Best Practices | **${BP}** | ${THRESHOLD_BEST_PRACTICES} |
| $(score_emoji "$SEO" "$THRESHOLD_SEO") SEO | **${SEO}** | ${THRESHOLD_SEO} |"

if [[ -n "$REPORT_URL" ]]; then
	BODY="${BODY}

[View Full Report](${REPORT_URL})"
fi

if [[ "$PASSED" == "true" ]]; then
	BODY="${BODY}

✅ All scores meet thresholds"
else
	BODY="${BODY}

⚠️ Some scores are below thresholds"
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
