#!/usr/bin/env bash
# Apply caller build-env lines to GITHUB_ENV without heredoc injection.
# SPDX-License-Identifier: MIT
set -euo pipefail

: "${BUILD_ENV:=}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

while IFS= read -r line || [[ -n "$line" ]]; do
	line="${line#"${line%%[![:space:]]*}"}"
	line="${line%"${line##*[![:space:]]}"}"
	[[ -z "$line" || "$line" =~ ^# ]] && continue
	if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
		echo "::error::Invalid build-env line rejected: ${line%%=*}" >&2
		exit 1
	fi
	echo "$line" >>"$GITHUB_ENV"
done <<<"$BUILD_ENV"
