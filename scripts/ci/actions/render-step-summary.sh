#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pure renderer (#1080): results.v1 document -> GitHub step summary.
#
# Reads only the results.json a runner wrote; no parser variables, no job
# outputs. The markdown matches what the per-runner summary steps printed
# before the contract existed, so step summaries do not change shape.
#
# Environment:
#   RESULTS_FILE  (required) Path to a results.v1 document
#   TITLE         (required) Heading text, e.g. "pytest Results"
#   EXTRA_ROWS    (optional) Newline-separated "Label|value" rows inserted
#                 before the Passed row (Playwright adds Browsers/Project/Grep)
#   GITHUB_STEP_SUMMARY  Destination (the actions library writes nothing
#                 when it is unset)

set -euo pipefail

: "${RESULTS_FILE:?RESULTS_FILE is required}"
: "${TITLE:?TITLE is required}"
: "${EXTRA_ROWS:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing/results.sh
source "$SCRIPT_DIR/../lib/testing/results.sh"

results_v1_validate "$RESULTS_FILE"

IFS=$'\t' read -r passed failed skipped total status exit_code coverage < <(
	jq -r '[.counts.passed, .counts.failed, .counts.skipped, .counts.total,
		.status, (.exit_code // "-"), (.coverage.lines // "-")] | @tsv' "$RESULTS_FILE"
)
# "-" marks an absent optional field: bash collapses adjacent tab
# separators, so an empty field would shift the ones after it.
[[ "$exit_code" == "-" ]] && exit_code=""
[[ "$coverage" == "-" ]] && coverage=""

# The document status is authoritative (a later gate or a missing report
# can fail a leg whose runner exited 0); a recorded non-zero exit code also
# fails it.
if [[ "$status" == "failed" || "$status" == "error" ]]; then
	status_icon=":x: Failed"
elif [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
	status_icon=":x: Failed"
else
	status_icon=":white_check_mark: Passed"
fi

add_github_summary "## ${TITLE}"
add_github_summary ""
add_github_summary "**Status:** ${status_icon}"
add_github_summary ""

if [[ "$total" -gt 0 ]]; then
	add_github_summary "| Metric | Value |"
	add_github_summary "|--------|-------|"
	while IFS= read -r row; do
		[[ -z "$row" ]] && continue
		add_github_summary "| ${row%%|*} | ${row#*|} |"
	done <<<"$EXTRA_ROWS"
	add_github_summary "| Passed | ${passed} |"
	add_github_summary "| Failed | ${failed} |"
	add_github_summary "| Skipped | ${skipped} |"
	add_github_summary "| Total | ${total} |"
	if [[ -n "$coverage" ]]; then
		add_github_summary "| Coverage | ${coverage}% |"
	fi
else
	add_github_summary "> No tests were found."
fi

add_github_summary ""
