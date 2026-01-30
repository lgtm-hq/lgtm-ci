#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate formatted PR comment from Playwright test results
#
# Required environment variables:
#   RESULTS_PATH - Path to Playwright JSON results file
#   REPORT_URL - URL to full report (optional)
#   SHOW_FAILED - Whether to show failed tests list
#   MAX_FAILED - Maximum number of failed tests to show

set -euo pipefail

: "${RESULTS_PATH:=playwright-report/results.json}"
: "${REPORT_URL:=}"
: "${SHOW_FAILED:=true}"
: "${MAX_FAILED:=10}"

# Check if results file exists
if [[ ! -f "$RESULTS_PATH" ]]; then
  echo "::warning::Playwright results not found at $RESULTS_PATH"
  {
    echo "body<<EOF_MISSING"
    echo "## Playwright Results"
    echo ""
    echo "⚠️ No test results found"
    echo "EOF_MISSING"
  } >> "$GITHUB_OUTPUT"
  echo "total=0" >> "$GITHUB_OUTPUT"
  echo "passed=0" >> "$GITHUB_OUTPUT"
  echo "failed=0" >> "$GITHUB_OUTPUT"
  echo "skipped=0" >> "$GITHUB_OUTPUT"
  echo "success=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Extract test counts from Playwright JSON report
if jq -e '.stats' "$RESULTS_PATH" > /dev/null 2>&1; then
  # Standard report format
  TOTAL=$(jq -r '.stats.expected + .stats.unexpected + .stats.flaky + .stats.skipped // 0' "$RESULTS_PATH")
  PASSED=$(jq -r '.stats.expected // 0' "$RESULTS_PATH")
  FAILED=$(jq -r '.stats.unexpected // 0' "$RESULTS_PATH")
  SKIPPED=$(jq -r '.stats.skipped // 0' "$RESULTS_PATH")
  FLAKY=$(jq -r '.stats.flaky // 0' "$RESULTS_PATH")
  DURATION=$(jq -r '.stats.duration // 0' "$RESULTS_PATH")
else
  # Fallback: count from suites
  TOTAL=$(jq '[.. | .tests? // [] | .[]] | length' "$RESULTS_PATH" 2>/dev/null || echo "0")
  PASSED=$(jq '[.. | .tests? // [] | .[] | select(.status == "passed")] | length' "$RESULTS_PATH" 2>/dev/null || echo "0")
  FAILED=$(jq '[.. | .tests? // [] | .[] | select(.status == "failed")] | length' "$RESULTS_PATH" 2>/dev/null || echo "0")
  SKIPPED=$(jq '[.. | .tests? // [] | .[] | select(.status == "skipped")] | length' "$RESULTS_PATH" 2>/dev/null || echo "0")
  FLAKY=0
  DURATION=0
fi

echo "total=$TOTAL" >> "$GITHUB_OUTPUT"
echo "passed=$PASSED" >> "$GITHUB_OUTPUT"
echo "failed=$FAILED" >> "$GITHUB_OUTPUT"
echo "skipped=$SKIPPED" >> "$GITHUB_OUTPUT"

SUCCESS="true"
[[ $FAILED -gt 0 ]] && SUCCESS="false"
echo "success=$SUCCESS" >> "$GITHUB_OUTPUT"

# Calculate pass rate
if [[ $TOTAL -gt 0 ]]; then
  PASS_RATE=$(( (PASSED * 100) / TOTAL ))
else
  PASS_RATE=0
fi

# Format duration
if [[ $DURATION -gt 0 ]]; then
  DURATION_SEC=$(( DURATION / 1000 ))
  DURATION_STR="${DURATION_SEC}s"
else
  DURATION_STR="N/A"
fi

# Status emoji
if [[ "$SUCCESS" == "true" ]]; then
  STATUS_EMOJI="✅"
  STATUS_TEXT="All tests passed"
else
  STATUS_EMOJI="❌"
  STATUS_TEXT="${FAILED} test(s) failed"
fi

# Generate comment body
BODY="## Playwright Test Results

${STATUS_EMOJI} **${STATUS_TEXT}**

| Metric | Count |
|--------|-------|
| Total | ${TOTAL} |
| ✅ Passed | ${PASSED} |
| ❌ Failed | ${FAILED} |
| ⏭️ Skipped | ${SKIPPED} |
| 🔄 Flaky | ${FLAKY:-0} |
| ⏱️ Duration | ${DURATION_STR} |
| 📊 Pass Rate | ${PASS_RATE}% |"

# Add failed tests list
if [[ "$SHOW_FAILED" == "true" && $FAILED -gt 0 ]]; then
  FAILED_TESTS=$(jq -r "[.. | .tests? // [] | .[] | select(.status == \"failed\") | .title] | .[0:${MAX_FAILED}] | .[]" "$RESULTS_PATH" 2>/dev/null || echo "")
  if [[ -n "$FAILED_TESTS" ]]; then
    BODY="${BODY}

<details>
<summary>Failed Tests (showing up to ${MAX_FAILED})</summary>

\`\`\`
${FAILED_TESTS}
\`\`\`

</details>"
  fi
fi

if [[ -n "$REPORT_URL" ]]; then
  BODY="${BODY}

[View Full Report](${REPORT_URL})"
fi

# Output body (handle multiline)
EOF_MARKER="EOF_$(date +%s)"
{
  echo "body<<$EOF_MARKER"
  echo "$BODY"
  echo "$EOF_MARKER"
} >> "$GITHUB_OUTPUT"
