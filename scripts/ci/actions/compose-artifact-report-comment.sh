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
#   RAW             - true: the report carries its own heading and footer, so
#                     it is emitted without the chrome (TITLE is not needed)
#   SANITIZE_MODE   - markdown (default) or report: the sanitiser mode the
#                     report passes through
#
# Security: the report is untrusted data, and the job posting it cannot trust
# the job that wrote it (#1676). It always passes through the shared
# sanitiser, raw or not: markdown mode (hidden characters removed, reserved
# <!-- lgtm-ci: marker broken) for a caller's own report, report mode
# (mentions, references, raw HTML, images and unsafe links removed as well)
# for a report a tool wrote from untrusted data, as lgtm-ci's link-check and
# validate workflows set. See docs/comment-sanitize.md. The title and footer
# name are sanitised as text by comment_chrome. Everything is emitted through
# printf or the sanitiser (no eval, no shell interpolation).

set -euo pipefail

# shellcheck source=../lib/github/comment_chrome.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/github/comment_chrome.sh"

REPORT_FILE="${REPORT_FILE:-}"
TITLE="${TITLE:-}"
RAW="${RAW:-false}"
SANITIZE_MODE="${SANITIZE_MODE:-markdown}"

case "$SANITIZE_MODE" in
markdown | report) ;;
*)
	echo "::error::SANITIZE_MODE must be markdown or report"
	exit 1
	;;
esac

# Write stdin to COMMENT_OUTPUT (or stdout). The body goes to a temporary file
# first and is moved into place when complete: COMMENT_OUTPUT can be the
# report file itself (a caller's report-file named like the output), and
# opening it for writing would truncate the report before it is read.
emit() {
	if [[ -z "${COMMENT_OUTPUT:-}" ]]; then
		cat
		return
	fi
	local tmp
	tmp="$(mktemp "${COMMENT_OUTPUT}.XXXXXX")"
	if ! cat >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$COMMENT_OUTPUT"
}

if [[ -z "$REPORT_FILE" || ! -f "$REPORT_FILE" || ! -s "$REPORT_FILE" ]]; then
	echo "::warning::report file not found or empty: ${REPORT_FILE:-<unset>} — skipping report comment"
	printf '' | emit
	exit 0
fi

if [[ "$RAW" == "true" ]]; then
	comment_sanitize "$SANITIZE_MODE" <"$REPORT_FILE" | emit
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
	comment_sanitize "$SANITIZE_MODE" <"$REPORT_FILE"
	printf '\n\n'
	comment_chrome_footer "${WORKFLOW_NAME:-lgtm-ci}"
} | emit
