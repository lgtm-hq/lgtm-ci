#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Node.js/npm version files
#
# Updates the .version field in package.json using jq.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3)
#
# Optional (via ECOSYSTEM_CONFIG_JSON):
#   package - Path to package.json (default: ./package.json)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:="{}"}"

# Resolve paths from config or defaults
PACKAGE_JSON=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '.package // "package.json"')

if [[ ! -f "$PACKAGE_JSON" ]]; then
	log_error "package.json not found at: $PACKAGE_JSON"
	exit 1
fi

# Ensure a version field already exists; don't silently add one
if ! jq -e 'has("version")' "$PACKAGE_JSON" >/dev/null; then
	log_error "[node] $PACKAGE_JSON has no 'version' field to update (expected $NEXT_VERSION)"
	exit 1
fi

log_info "[node] Updating $PACKAGE_JSON → $NEXT_VERSION"

# Detect existing indentation by looking at the first character of
# line 2 (the first top-level key in a well-formed package.json).
INDENT=$(awk 'NR == 2 { match($0, /^[[:space:]]+/); if (RLENGTH > 0) print substr($0, 1, RLENGTH); exit }' "$PACKAGE_JSON")

if [[ "$INDENT" == $'\t'* ]]; then
	JQ_INDENT="--tab"
elif [[ ${#INDENT} -gt 0 ]]; then
	JQ_INDENT="--indent ${#INDENT}"
else
	JQ_INDENT="--indent 2"
fi

# Update version field, preserving formatting.
# SC2086: $JQ_INDENT must word-split into either "--indent N" (two args)
# or "--tab" (one arg), so unquoted expansion is intentional.
# SC2016: '.version = $v' is a jq filter — $v is a jq variable (set by
# --arg v), not a shell variable; single quotes prevent shell expansion.
# shellcheck disable=SC2086,SC2016
write_file_atomic "$PACKAGE_JSON" \
	jq $JQ_INDENT --arg v "$NEXT_VERSION" '.version = $v' "$PACKAGE_JSON"

# Verify the write
ACTUAL=$(jq -r '.version' "$PACKAGE_JSON")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[node] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[node] $PACKAGE_JSON updated to $NEXT_VERSION"
