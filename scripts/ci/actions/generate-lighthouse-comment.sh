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

: "${RESULTS_PATH:?RESULTS_PATH is required}"
: "${REPORT_URL:=}"
: "${THRESHOLD_PERFORMANCE:=80}"
: "${THRESHOLD_ACCESSIBILITY:=90}"
: "${THRESHOLD_BEST_PRACTICES:=80}"
: "${THRESHOLD_SEO:=80}"

# Find the results file
if [[ -d "$RESULTS_PATH" ]]; then
  RESULTS_FILE=$(find "$RESULTS_PATH" -name "*.json" -type f | head -1)
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

echo "performance=$PERF" >> "$GITHUB_OUTPUT"
echo "accessibility=$A11Y" >> "$GITHUB_OUTPUT"
echo "best-practices=$BP" >> "$GITHUB_OUTPUT"
echo "seo=$SEO" >> "$GITHUB_OUTPUT"

# Check thresholds
PASSED=true
[[ $PERF -lt $THRESHOLD_PERFORMANCE ]] && PASSED=false
[[ $A11Y -lt $THRESHOLD_ACCESSIBILITY ]] && PASSED=false
[[ $BP -lt $THRESHOLD_BEST_PRACTICES ]] && PASSED=false
[[ $SEO -lt $THRESHOLD_SEO ]] && PASSED=false

echo "passed=$PASSED" >> "$GITHUB_OUTPUT"

# Helper function for score emoji
score_emoji() {
  local score=$1
  local threshold=$2
  if [[ $score -ge 90 ]]; then
    echo "🟢"
  elif [[ $score -ge $threshold ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

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

# Output body (handle multiline)
EOF_MARKER="EOF_$(date +%s)"
{
  echo "body<<$EOF_MARKER"
  echo "$BODY"
  echo "$EOF_MARKER"
} >> "$GITHUB_OUTPUT"
