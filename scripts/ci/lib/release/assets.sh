#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve release asset paths from newline-separated glob patterns

[[ -n "${_RELEASE_ASSETS_LOADED:-}" ]] && return 0
readonly _RELEASE_ASSETS_LOADED=1

# Collect regular files matching newline-separated glob patterns.
# Sets RELEASE_ASSET_FILES array. Prints the match count to stdout.
# Usage: release_collect_asset_files "$FILE_PATTERNS"
release_collect_asset_files() {
	local patterns_input="${1:?file patterns are required}"
	local -a collected=()
	local pattern file
	local nullglob_was_set=0

	shopt -q nullglob && nullglob_was_set=1
	shopt -s nullglob
	while IFS= read -r pattern || [[ -n "$pattern" ]]; do
		[[ -z "${pattern// /}" ]] && continue
		local -a matches=()
		# shellcheck disable=SC2206 # Glob expansion is intentional for release patterns
		matches=($pattern)
		local file
		for file in ${matches[@]+"${matches[@]}"}; do
			if [[ -f "$file" ]]; then
				collected+=("$file")
			fi
		done
	done <<<"$patterns_input"
	if ((nullglob_was_set == 0)); then
		shopt -u nullglob
	fi

	RELEASE_ASSET_FILES=("${collected[@]+"${collected[@]}"}")
	echo "${#collected[@]}"
}

export -f release_collect_asset_files
