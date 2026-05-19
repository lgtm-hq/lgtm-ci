#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve and execute a caller-provided script path safely.
#
# Environment variables:
#   DEFAULT_SCRIPT_PATH - Fallback script relative to GITHUB_WORKSPACE
#   RAW_SCRIPT_PATH     - Optional override from workflow inputs
#   GITHUB_WORKSPACE    - Repository workspace root

set -euo pipefail

: "${DEFAULT_SCRIPT_PATH:?DEFAULT_SCRIPT_PATH is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

RAW_SCRIPT_PATH="${RAW_SCRIPT_PATH:-}"

resolve_path() {
	local path="$1"
	local resolved
	local workspace

	if [[ "$path" == *".."* ]]; then
		echo "Script path must not contain '..'" >&2
		exit 1
	fi

	workspace="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
	if [[ "$path" = /* ]]; then
		resolved="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path")"
	else
		resolved="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$workspace/$path")"
	fi

	case "$resolved" in
	"$workspace") ;;
	"$workspace"/*) ;;
	*)
		echo "Script resolves outside the workspace: $resolved" >&2
		exit 1
		;;
	esac

	if [[ ! -f "$resolved" ]]; then
		echo "Script not found: $resolved" >&2
		exit 1
	fi

	if [[ ! -x "$resolved" ]]; then
		chmod +x "$resolved"
	fi

	printf '%s' "$resolved"
}

if [[ -n "$RAW_SCRIPT_PATH" ]]; then
	SCRIPT_PATH="$(resolve_path "$RAW_SCRIPT_PATH")"
else
	SCRIPT_PATH="$(resolve_path "$DEFAULT_SCRIPT_PATH")"
fi

exec bash "$SCRIPT_PATH"
