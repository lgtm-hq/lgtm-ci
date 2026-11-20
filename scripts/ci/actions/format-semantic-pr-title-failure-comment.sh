#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Format PR comment body for semantic PR title validation failures
#
# Environment variables:
#   LENGTH_ERROR - Optional length validation error message
#   SEMANTIC_ERROR - Optional semantic validation error message
#   ALLOWED_TYPES - Newline-delimited allowed commit types
#   COMMENT_FILE - Output path for the comment body
#
# The error messages quote the pull request title and go into a sanitised
# code fence; each allowed type is sanitised text (#1676,
# docs/comment-sanitize.md).

set -euo pipefail

# shellcheck source=../lib/github/comment_sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)/../lib/github/comment_sanitize.sh"

: "${LENGTH_ERROR:=}"
: "${SEMANTIC_ERROR:=}"
: "${ALLOWED_TYPES:?ALLOWED_TYPES is required}"
: "${COMMENT_FILE:?COMMENT_FILE is required}"

# combined_error only joins the two messages; it reaches the comment through
# comment_sanitize fence below.
combined_error=""
if [[ -n "${LENGTH_ERROR//[[:space:]]/}" ]]; then
	combined_error="$LENGTH_ERROR" # comment-safe: joined, fenced below
fi
if [[ -n "${SEMANTIC_ERROR//[[:space:]]/}" ]]; then
	if [[ -n "$combined_error" ]]; then
		combined_error="${combined_error}"$'\n\n'"${SEMANTIC_ERROR}" # comment-safe: joined, fenced below
	else
		combined_error="$SEMANTIC_ERROR" # comment-safe: joined, fenced below
	fi
fi

if [[ -z "${combined_error//[[:space:]]/}" ]]; then
	echo "::error::At least one of LENGTH_ERROR or SEMANTIC_ERROR is required"
	exit 1
fi

types_block="  - (none configured)"
if [[ -n "${ALLOWED_TYPES//[[:space:]]/}" ]]; then
	mapfile -d '' type_texts < <(printf '%s' "$ALLOWED_TYPES" | sed '/^[[:space:]]*$/d' | tr '\n' '\0' |
		comment_sanitize text --nul)
	printf -v types_block '  - %s\n' "${type_texts[@]}"
	types_block="${types_block%$'\n'}"
fi

error_block="$(printf '%s' "$combined_error" | comment_sanitize fence)"

cat >"$COMMENT_FILE" <<LGTM_COMMENT_BODY
### Semantic PR title check failed

Your PR title must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

**Expected format:** \`type(scope): description\`

**Allowed types:**
${types_block}

**Details:**

${error_block}
LGTM_COMMENT_BODY
