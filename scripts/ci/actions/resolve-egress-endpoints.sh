#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve allowed-endpoints from explicit list or egress preset
#
# Required environment variables:
#   GITHUB_OUTPUT - GitHub Actions output file
#   EGRESS_POLICY - audit or block
#   ALLOWED_ENDPOINTS - Caller host:port list (multiline)
#   EGRESS_PRESET     - Preset name when using preset baseline (optional)
#   ALLOWED_ENDPOINTS_MODE - replace (default) or append
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
: "${ALLOWED_ENDPOINTS_MODE:=replace}"

case "$EGRESS_POLICY" in
audit | block) ;;
*)
	echo "resolve-egress-endpoints.sh: invalid EGRESS_POLICY '$EGRESS_POLICY' (expected 'audit' or 'block')" >&2
	exit 1
	;;
esac

case "$ALLOWED_ENDPOINTS_MODE" in
replace | append) ;;
*)
	echo "resolve-egress-endpoints.sh: invalid ALLOWED_ENDPOINTS_MODE '$ALLOWED_ENDPOINTS_MODE' (expected 'replace' or 'append')" >&2
	exit 1
	;;
esac

explicit="$(egress_normalize_endpoint_lines "$ALLOWED_ENDPOINTS")"

preset_trimmed="${EGRESS_PRESET#"${EGRESS_PRESET%%[![:space:]]*}"}"
preset_trimmed="${preset_trimmed%"${preset_trimmed##*[![:space:]]}"}"

preset_lines=""
if [[ "$EGRESS_POLICY" == "block" && -n "$preset_trimmed" ]]; then
	preset_lines="$(egress_preset_endpoints "$preset_trimmed")" || exit 1
fi

resolved=""

if [[ "$EGRESS_POLICY" == "audit" ]]; then
	resolved="$explicit"
elif [[ "$ALLOWED_ENDPOINTS_MODE" == "replace" ]]; then
	if [[ -n "$explicit" ]]; then
		resolved="$explicit"
	elif [[ -n "$preset_lines" ]]; then
		resolved="$preset_lines"
	fi
else
	if [[ -n "$preset_lines" || -n "$explicit" ]]; then
		resolved="$(egress_merge_endpoint_lines "$preset_lines" "$explicit")"
	fi
fi

if [[ "$EGRESS_POLICY" == "block" && -z "${resolved//[[:space:]]/}" ]]; then
	echo "resolve-egress-endpoints.sh: egress-policy block requires non-empty allowed-endpoints or egress-preset" >&2
	exit 1
fi

set_github_output_multiline "allowed-endpoints" "$resolved"
