#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve allowed-endpoints from explicit list or egress preset
#
# Required environment variables:
#   GITHUB_OUTPUT - GitHub Actions output file
#   EGRESS_POLICY - audit or block
#   ALLOWED_ENDPOINTS - Caller override (multiline host:port)
#   EGRESS_PRESET     - Preset name when allowed-endpoints is empty (optional)
#
# Outputs (GITHUB_OUTPUT):
#   allowed-endpoints - Resolved allowlist for step-security/harden-runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/egress.sh
source "$LIB_DIR/egress.sh"
# shellcheck source=../lib/github/output.sh
source "$LIB_DIR/github/output.sh"

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${EGRESS_POLICY:=block}"
: "${ALLOWED_ENDPOINTS:=}"
: "${EGRESS_PRESET:=}"

case "$EGRESS_POLICY" in
audit | block) ;;
*)
	echo "resolve-egress-endpoints.sh: invalid EGRESS_POLICY '$EGRESS_POLICY' (expected 'audit' or 'block')" >&2
	exit 1
	;;
esac

normalize_allowed_endpoints() {
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

resolved=""
resolved="$(normalize_allowed_endpoints "$ALLOWED_ENDPOINTS")"

preset_trimmed="${EGRESS_PRESET#"${EGRESS_PRESET%%[![:space:]]*}"}"
preset_trimmed="${preset_trimmed%"${preset_trimmed##*[![:space:]]}"}"

if [[ -z "$resolved" && "$EGRESS_POLICY" == "block" && -n "$preset_trimmed" ]]; then
	resolved="$(egress_preset_endpoints "$preset_trimmed")" || exit 1
fi

if [[ "$EGRESS_POLICY" == "block" && -z "${resolved//[[:space:]]/}" ]]; then
	echo "resolve-egress-endpoints.sh: egress-policy block requires non-empty allowed-endpoints or egress-preset" >&2
	exit 1
fi

set_github_output_multiline "allowed-endpoints" "$resolved"
