#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Normalize semantic PR types/scopes for action-semantic-pull-request
#
# Required environment variables:
#   GITHUB_OUTPUT - GitHub Actions output file
#   TYPES_INPUT   - Caller override for allowed types (optional)
#   SCOPES_INPUT  - Caller override for allowed scopes (optional)

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${TYPES_INPUT:=}"
: "${SCOPES_INPUT:=}"

normalize_list() {
	local value="$1"
	if [[ -z "${value//[[:space:]]/}" ]]; then
		printf ''
		return
	fi
	if [[ "$value" != *$'\n'* ]] && [[ "$value" == *","* ]]; then
		value="${value//,/$'\n'}"
	fi
	printf '%s' "$value"
}

write_output() {
	local name="$1"
	local value="$2"
	{
		echo "${name}<<EOF"
		printf '%s\n' "$value"
		echo EOF
	} >>"$GITHUB_OUTPUT"
}

default_types=$'feat\nfix\ndocs\nstyle\nrefactor\nperf\ntest\nbuild\nci\nchore\nrevert'

if [[ -z "${TYPES_INPUT//[[:space:]]/}" ]]; then
	types="$default_types"
else
	types="$(normalize_list "$TYPES_INPUT")"
fi
write_output types "$types"

scopes="$(normalize_list "$SCOPES_INPUT")"
write_output scopes "$scopes"
