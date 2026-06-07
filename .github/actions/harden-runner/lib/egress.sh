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

# Deduplicate normalized host:port lines; preserve first-seen order (O(n) via awk).
_egress_dedupe_normalized_endpoint_lines() {
	local normalized="$1"

	if [[ -z "$normalized" ]]; then
		printf ''
		return
	fi

	printf '%s' "$(awk '!seen[$0]++' <<<"$normalized")"
}

# Deduplicate host:port lines; preserve first-seen order (O(n) via awk).
egress_dedupe_endpoint_lines() {
	local raw="$1"
	local normalized

	normalized="$(egress_normalize_endpoint_lines "$raw")"
	_egress_dedupe_normalized_endpoint_lines "$normalized"
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
	_egress_dedupe_normalized_endpoint_lines "$combined"
}

export -f _egress_dedupe_normalized_endpoint_lines
export -f egress_normalize_endpoint_lines egress_dedupe_endpoint_lines egress_merge_endpoint_lines
