#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve a default Node.js version from a caller checkout (#1372)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/node/version.sh"
#   node_resolve_default_version [dir]    # prints "<version>\t<source>"
#
# Resolution order (first usable source wins):
#   1. .nvmrc
#   2. .node-version
#   3. package.json engines.node, reduced to its lowest major
#      (">=20 <23" -> 20, "^22.1" -> 22, "20.x || 22" -> 20)
#   4. lts/*
#
# Upper-bound-only terms ("<23") are ignored when reducing a range, so they
# never pick a version the project does not support. The <source> field names
# the file that won, or "fallback".

[[ -n "${_LGTM_CI_NODE_VERSION_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NODE_VERSION_LOADED=1

# Print the first non-blank line of a file, whitespace trimmed (empty if none).
_node_version_first_line() {
	local file="$1" line=""
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line//$'\r'/}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		if [[ -n "$line" ]]; then
			printf '%s' "$line"
			return 0
		fi
	done <"$file"
}

# Reduce a semver range to its lowest lower-bound major; empty when none.
node_range_lowest_major() {
	local range="$1" token major lowest="" skip_next=false
	local bare_operator='^[<>=^~]+$'
	range="${range//||/ }"
	for token in $range; do
		# A bare operator ("<", "<=", ">=") applies to the next token.
		if [[ "$token" =~ $bare_operator ]]; then
			[[ "$token" == "<"* ]] && skip_next=true
			continue
		fi
		if [[ "$skip_next" == true ]]; then
			skip_next=false
			continue
		fi
		# Skip upper-bound-only terms such as "<23" or "<=22".
		[[ "$token" == "<"* ]] && continue
		token="${token#"${token%%[^>=^~v]*}"}"
		[[ "$token" =~ ^([0-9]+) ]] || continue
		major="${BASH_REMATCH[1]}"
		if [[ -z "$lowest" ]] || ((10#$major < 10#$lowest)); then
			lowest="$major"
		fi
	done
	printf '%s' "$lowest"
}

# Print the package.json engines.node string (empty when absent or invalid).
_node_version_engines() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	if ! command -v python3 >/dev/null 2>&1; then
		echo "::warning::python3 is unavailable; package.json engines.node was not consulted for the Node version" >&2
		return 0
	fi
	if ! python3 - "$file" <<'PY' 2>/dev/null; then
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get("engines", {}).get("node", "")
if isinstance(value, str):
    print(value.strip())
PY
		echo "::warning::${file} could not be parsed; package.json engines.node was not consulted for the Node version" >&2
	fi
	return 0
}

# Print "<version>\t<source>" for the checkout in $1 (default: cwd).
node_resolve_default_version() {
	local dir="${1:-.}" name value engines
	for name in .nvmrc .node-version; do
		value="$(_node_version_first_line "${dir}/${name}")"
		if [[ -n "$value" ]]; then
			printf '%s\t%s\n' "$value" "$name"
			return 0
		fi
	done
	engines="$(_node_version_engines "${dir}/package.json")"
	if [[ -n "$engines" ]]; then
		value="$(node_range_lowest_major "$engines")"
		if [[ -n "$value" ]]; then
			printf '%s\t%s\n' "$value" "package.json engines.node"
			return 0
		fi
	fi
	printf '%s\t%s\n' "lts/*" "fallback"
}
