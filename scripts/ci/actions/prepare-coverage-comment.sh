#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Rewrite the coverage comment title for PR posting.
#
# Required environment variables:
#   COMMENT_BODY   - Markdown body from generate-coverage-comment
#   COMMENT_TITLE  - Replacement for the default "## Coverage Report" heading
#   COMMENT_OUTPUT - Path to write the transformed comment

set -euo pipefail

: "${COMMENT_BODY:?COMMENT_BODY is required}"
: "${COMMENT_TITLE:?COMMENT_TITLE is required}"
: "${COMMENT_OUTPUT:?COMMENT_OUTPUT is required}"

printf '%s\n' "$COMMENT_BODY" |
	sed "1s/^## Coverage Report$/## ${COMMENT_TITLE}/" >"$COMMENT_OUTPUT"
