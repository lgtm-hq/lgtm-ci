#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Format PR comment body for semantic PR title validation failures
#
# Environment variables:
#   LENGTH_ERROR - Optional length validation error message
#   SEMANTIC_ERROR - Optional semantic validation error message
#   ALLOWED_TYPES - Newline-delimited allowed commit types
#   COMMENT_FILE - Output path for the comment body

set -euo pipefail

: "${LENGTH_ERROR:=}"
: "${SEMANTIC_ERROR:=}"
: "${ALLOWED_TYPES:?ALLOWED_TYPES is required}"
: "${COMMENT_FILE:?COMMENT_FILE is required}"

combined_error=""
if [[ -n "${LENGTH_ERROR//[[:space:]]/}" ]]; then
	combined_error="$LENGTH_ERROR"
fi
if [[ -n "${SEMANTIC_ERROR//[[:space:]]/}" ]]; then
	if [[ -n "$combined_error" ]]; then
		combined_error="${combined_error}"$'\n\n'"${SEMANTIC_ERROR}"
	else
		combined_error="$SEMANTIC_ERROR"
	fi
fi

if [[ -z "${combined_error//[[:space:]]/}" ]]; then
	echo "::error::At least one of LENGTH_ERROR or SEMANTIC_ERROR is required"
	exit 1
fi

types_block="$ALLOWED_TYPES"
if [[ -n "${types_block//[[:space:]]/}" ]]; then
	types_block=$(printf '%s' "$ALLOWED_TYPES" | sed 's/^/  - /')
else
	types_block="  - (none configured)"
fi

safe_error="${combined_error//\`\`\`/\\\`\\\`\\\`}"

cat >"$COMMENT_FILE" <<EOF
### Semantic PR title check failed

Your PR title must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

**Expected format:** \`type(scope): description\`

**Allowed types:**
${types_block}

**Details:**

\`\`\`
${safe_error}
\`\`\`
EOF
