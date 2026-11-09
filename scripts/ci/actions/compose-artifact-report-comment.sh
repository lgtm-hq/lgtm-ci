#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Compose a PR comment body that wraps a downloaded markdown report
#          with the shared comment chrome (heading, optional status, footer).
#
# Environment variables expected:
#   REPORT_FILE     - Path to the markdown report (required). When missing or
#                     empty the script warns and writes an empty body so the
#                     caller can delete-on-empty.
#   TITLE           - Heading text (required)
#   UPSTREAM_RESULT - Optional upstream job result. success -> PASSED,
#                     failure -> FAILED, cancelled/skipped -> skipped marker;
#                     empty (or anything else) -> no status line
#   WORKFLOW_NAME   - Optional name for the footer (default: lgtm-ci)
#   COMMENT_OUTPUT  - Optional output file. When unset, the body is printed to
#                     stdout (used by unit tests).
#
# Security: the report is untrusted data. It is only emitted with cat; all
# other values go through printf (no eval, no shell interpolation).

set -euo pipefail

# shellcheck source=../lib/github/comment_chrome.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/github/comment_chrome.sh"

REPORT_FILE="${REPORT_FILE:-}"
TITLE="${TITLE:-}"

emit() {
	if [[ -n "${COMMENT_OUTPUT:-}" ]]; then
		cat >"$COMMENT_OUTPUT"
	else
		cat
	fi
}

if [[ -z "$REPORT_FILE" || ! -f "$REPORT_FILE" || ! -s "$REPORT_FILE" ]]; then
	echo "::warning::report file not found or empty: ${REPORT_FILE:-<unset>} — skipping report comment"
	printf '' | emit
	exit 0
fi

if [[ -z "$TITLE" ]]; then
	echo "::error::TITLE is required"
	exit 1
fi

STATUS_TEXT="$(comment_chrome_result_status "${UPSTREAM_RESULT:-}")"

{
	comment_chrome_heading "$TITLE" "$STATUS_TEXT"
	printf '\n'
	cat "$REPORT_FILE"
	printf '\n\n'
	comment_chrome_footer "${WORKFLOW_NAME:-lgtm-ci}"
} | emit
