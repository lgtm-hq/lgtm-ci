#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Normalize semantic PR types/scopes for action-semantic-pull-request
#
# Required environment variables:
#   GITHUB_OUTPUT - GitHub Actions output file
#   TYPES_INPUT   - Caller override for allowed types (optional)
#   SCOPES_INPUT  - Caller override for allowed scopes (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

if [[ -f "$LIB_DIR/github/output.sh" ]]; then
	# shellcheck source=../lib/github/output.sh
	source "$LIB_DIR/github/output.sh"
fi

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${TYPES_INPUT:=}"
: "${SCOPES_INPUT:=}"

normalize_list() {
	local value="$1"
	local -a lines=()
	local line trimmed

	if [[ -z "${value//[[:space:]]/}" ]]; then
		printf ''
		return
	fi

	if [[ "$value" == *","* ]]; then
		value="${value//,/$'\n'}"
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		trimmed="${line#"${line%%[![:space:]]*}"}"
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
		if [[ -n "$trimmed" ]]; then
			lines+=("$trimmed")
		fi
	done <<<"$value"

	if ((${#lines[@]} == 0)); then
		printf ''
		return
	fi

	local IFS=$'\n'
	printf '%s' "${lines[*]}"
}

default_types=$'feat\nfix\ndocs\nstyle\nrefactor\nperf\ntest\nbuild\nci\nchore\nrevert'

if [[ -z "${TYPES_INPUT//[[:space:]]/}" ]]; then
	types="$default_types"
else
	types="$(normalize_list "$TYPES_INPUT")"
fi
set_github_output_multiline types "$types"

scopes="$(normalize_list "$SCOPES_INPUT")"
if [[ -n "${scopes//[[:space:]]/}" ]]; then
	set_github_output_multiline scopes "$scopes"
fi
