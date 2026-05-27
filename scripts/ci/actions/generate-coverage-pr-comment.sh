#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate PR comment body for reusable coverage PR comment workflow
#
# Environment variables:
#   COVERAGE_PERCENT - Overall coverage percentage
#   THRESHOLD        - Minimum coverage threshold (optional, default 0)
#   COMMENT_TITLE    - PR comment title (optional, default "Coverage Report")
#   PASSED           - Whether coverage meets threshold (optional, default "true")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

if [[ -f "$LIB_DIR/github/output.sh" ]]; then
	# shellcheck source=../lib/github/output.sh
	source "$LIB_DIR/github/output.sh"
fi

COVERAGE_PERCENT="${COVERAGE_PERCENT:?COVERAGE_PERCENT is required}"
THRESHOLD="${THRESHOLD:-0}"
COMMENT_TITLE="${COMMENT_TITLE:-Coverage Report}"
PASSED="${PASSED:-true}"

STATUS_EMOJI="✅"
if [[ "$PASSED" != "true" ]]; then
	STATUS_EMOJI="❌"
fi

BODY="## ${COMMENT_TITLE}

${STATUS_EMOJI} **Coverage: ${COVERAGE_PERCENT}%**"
if awk -v t="$THRESHOLD" 'BEGIN{exit(!(t > 0))}'; then
	BODY="${BODY} (threshold: ${THRESHOLD}%)"
fi

if declare -f set_github_output_multiline &>/dev/null; then
	set_github_output_multiline "comment-body" "$BODY"
elif [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	EOF_MARKER="LGTM_CI_EOF_$$_$(date +%s)"
	{
		echo "comment-body<<${EOF_MARKER}"
		echo "$BODY"
		echo "${EOF_MARKER}"
	} >>"$GITHUB_OUTPUT"
else
	printf '%s\n' "$BODY"
fi
