#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Format PR comment body for semantic PR title validation failures
#
# Required environment variables:
#   SEMANTIC_ERROR - Validation error message
#   ALLOWED_TYPES - Newline-delimited allowed commit types
#   COMMENT_FILE - Output path for the comment body

set -euo pipefail

: "${SEMANTIC_ERROR:?SEMANTIC_ERROR is required}"
: "${ALLOWED_TYPES:?ALLOWED_TYPES is required}"
: "${COMMENT_FILE:?COMMENT_FILE is required}"

types_block="$ALLOWED_TYPES"
if [[ -n "${types_block//[[:space:]]/}" ]]; then
	types_block=$(printf '%s' "$ALLOWED_TYPES" | sed 's/^/  - /')
else
	types_block="  - (none configured)"
fi

cat >"$COMMENT_FILE" <<EOF
### Semantic PR title check failed

Your PR title must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

**Expected format:** \`type(scope): description\`

**Allowed types:**
${types_block}

**Details:**

\`\`\`
${SEMANTIC_ERROR}
\`\`\`
EOF
