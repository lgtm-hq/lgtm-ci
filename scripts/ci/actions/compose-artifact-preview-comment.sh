#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Compose a sticky PR comment body that links to a build artifact for
#          download, optionally prefixed with a caller-provided build summary.
#
# Environment variables expected:
#   ARTIFACT_NAME - Display name of the uploaded artifact (required)
#   ARTIFACT_URL  - actions/upload-artifact v4 `artifact-url` output. When empty
#                   the script emits a warning and writes an empty body so the
#                   caller can delete-on-empty rather than post a broken link.
#   SUMMARY       - Optional inline markdown summary prepended to the comment
#   SUMMARY_FILE  - Optional path to a markdown file; takes precedence over
#                   SUMMARY when it exists and is non-empty
#   COMMENT_OUTPUT - Optional output file. When unset, the body is printed to
#                   stdout (used by unit tests).
#
# Security: all values arrive via the environment and are emitted with printf
# (no eval, no shell interpolation of untrusted data).

set -euo pipefail

ARTIFACT_NAME="${ARTIFACT_NAME:-}"
ARTIFACT_URL="${ARTIFACT_URL:-}"

emit() {
	if [[ -n "${COMMENT_OUTPUT:-}" ]]; then
		cat >"$COMMENT_OUTPUT"
	else
		cat
	fi
}

# Graceful degrade: without a download URL there is nothing to link. Emit an
# empty body so a delete-on-empty upsert removes any stale comment, and warn.
if [[ -z "$ARTIFACT_URL" ]]; then
	echo "::warning::artifact-url is empty — skipping artifact preview comment (upstream upload may have failed)"
	printf '' | emit
	exit 0
fi

if [[ -z "$ARTIFACT_NAME" ]]; then
	echo "::error::ARTIFACT_NAME is required when ARTIFACT_URL is provided"
	exit 1
fi

# Resolve the optional summary: a non-empty file wins over the inline input.
SUMMARY_TEXT=""
if [[ -n "${SUMMARY_FILE:-}" ]]; then
	if [[ -f "$SUMMARY_FILE" && -s "$SUMMARY_FILE" ]]; then
		SUMMARY_TEXT="$(cat "$SUMMARY_FILE")"
	else
		echo "::warning::summary-file not found or empty: ${SUMMARY_FILE}"
	fi
fi
if [[ -z "$SUMMARY_TEXT" && -n "${SUMMARY:-}" ]]; then
	SUMMARY_TEXT="$SUMMARY"
fi

{
	if [[ -n "$SUMMARY_TEXT" ]]; then
		printf '%s\n\n' "$SUMMARY_TEXT"
	fi
	printf '⬇ **[Download %s](%s)**\n\n' "$ARTIFACT_NAME" "$ARTIFACT_URL"
	printf '%s\n' "<sub>Downloads a \`.zip\`; requires being signed in to GitHub with access to this repository. This is a reviewer convenience, not a public preview URL.</sub>"
} | emit
