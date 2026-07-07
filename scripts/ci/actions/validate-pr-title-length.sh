#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate PR title length when max-length is configured
#
# Environment variables:
#   TITLE - PR title to validate (required)
#   MAX_LENGTH - Maximum title length; defaults to 0 (no limit)
#   GITHUB_OUTPUT - GitHub Actions output file (required)

set -euo pipefail

: "${TITLE:?TITLE is required}"
: "${MAX_LENGTH:=0}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if ! [[ "$MAX_LENGTH" =~ ^[0-9]+$ ]]; then
	echo "::warning::MAX_LENGTH '$MAX_LENGTH' is not a valid number, skipping length check"
	printf 'error=\n' >>"$GITHUB_OUTPUT"
	exit 0
fi

if [[ "$MAX_LENGTH" -eq 0 ]]; then
	printf 'error=\n' >>"$GITHUB_OUTPUT"
	exit 0
fi

if [[ ${#TITLE} -gt $MAX_LENGTH ]]; then
	message="PR title exceeds maximum length of ${MAX_LENGTH} characters (${#TITLE})"
	echo "::error::$message"
	printf 'error=%s\n' "$message" >>"$GITHUB_OUTPUT"
	exit 1
fi

printf 'error=\n' >>"$GITHUB_OUTPUT"
