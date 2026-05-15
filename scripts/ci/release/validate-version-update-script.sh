#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate and canonicalize a repo-specific version update script.
#
# Environment variables:
#   RAW_SCRIPT_PATH - Script path supplied by the caller
#   GITHUB_WORKSPACE - Repository workspace root
#   GITHUB_OUTPUT - GitHub Actions output file

set -euo pipefail

: "${RAW_SCRIPT_PATH:?RAW_SCRIPT_PATH is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ ! -f "$RAW_SCRIPT_PATH" ]]; then
	printf '::error::version-update-script not found: %s\n' "$RAW_SCRIPT_PATH" >&2
	exit 1
fi

resolve_path() {
	local path="$1"

	python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path"
}

resolved="$(resolve_path "$RAW_SCRIPT_PATH")"
workspace="$(cd "$GITHUB_WORKSPACE" && pwd -P)"

case "$resolved" in
"$workspace") ;;
"$workspace"/*) ;;
*)
	printf '::error::version-update-script resolves outside the workspace: %s\n' "$resolved" >&2
	exit 1
	;;
esac

if [[ ! -x "$resolved" ]]; then
	chmod +x "$resolved"
fi

printf 'resolved=%s\n' "$resolved" >>"$GITHUB_OUTPUT"
printf 'Validated version update script: %s\n' "$resolved"
