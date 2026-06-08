#!/usr/bin/env bash
# Resolve site artifact upload path from explicit input or first lychee-path.
# SPDX-License-Identifier: MIT
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${SITE_ARTIFACT_PATH:=}"
: "${LYCHEE_PATHS:=.}"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

if [[ -n "$(trim "$SITE_ARTIFACT_PATH")" ]]; then
	resolved="$(trim "$SITE_ARTIFACT_PATH")"
else
	resolved="$(trim "${LYCHEE_PATHS%%,*}")"
fi

echo "path=$resolved" >>"$GITHUB_OUTPUT"
