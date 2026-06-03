#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for egress preset utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/egress.sh"

[[ -n "${_LGTM_CI_EGRESS_LOADED:-}" ]] && return 0

_LGTM_CI_EGRESS_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/egress" && pwd)" || {
	echo "egress.sh: cannot resolve egress assets directory" >&2
	return 1
}

[[ -f "$_LGTM_CI_EGRESS_DIR/presets.sh" ]] || {
	echo "egress.sh: missing presets.sh in $_LGTM_CI_EGRESS_DIR" >&2
	return 1
}
# shellcheck source=egress/presets.sh
source "$_LGTM_CI_EGRESS_DIR/presets.sh"
readonly _LGTM_CI_EGRESS_LOADED=1

# Normalize multiline host:port list (trim lines, drop blanks).
egress_normalize_endpoint_lines() {
	local raw="$1"
	local -a lines=()
	local line trimmed

	if [[ -z "${raw//[[:space:]]/}" ]]; then
		printf ''
		return
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		trimmed="${line#"${line%%[![:space:]]*}"}"
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
		if [[ -n "$trimmed" ]]; then
			lines+=("$trimmed")
		fi
	done <<<"$raw"

	if ((${#lines[@]} == 0)); then
		printf ''
		return
	fi

	local IFS=$'\n'
	printf '%s' "${lines[*]}"
}

# Deduplicate host:port lines; preserve first-seen order (bash 3.2 compatible).
egress_dedupe_endpoint_lines() {
	local raw="$1"
	local -a unique=()
	local line existing found

	if [[ -z "${raw//[[:space:]]/}" ]]; then
		printf ''
		return
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -z "$line" ]] && continue
		found=0
		if ((${#unique[@]} > 0)); then
			for existing in "${unique[@]}"; do
				if [[ "$existing" == "$line" ]]; then
					found=1
					break
				fi
			done
		fi
		if [[ "$found" -eq 0 ]]; then
			unique+=("$line")
		fi
	done <<<"$raw"

	if ((${#unique[@]} == 0)); then
		printf ''
		return
	fi

	local IFS=$'\n'
	printf '%s' "${unique[*]}"
}

# Merge multiple multiline endpoint lists (empty parts skipped), then dedupe.
egress_merge_endpoint_lines() {
	local combined="" part normalized
	for part in "$@"; do
		normalized="$(egress_normalize_endpoint_lines "$part")"
		[[ -z "$normalized" ]] && continue
		if [[ -z "$combined" ]]; then
			combined="$normalized"
		else
			combined="${combined}"$'\n'"${normalized}"
		fi
	done
	egress_dedupe_endpoint_lines "$combined"
}

export -f egress_normalize_endpoint_lines egress_dedupe_endpoint_lines egress_merge_endpoint_lines
