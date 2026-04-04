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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:={}}"

# Resolve paths from config or defaults
PACKAGE_JSON=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '.package // "package.json"')

if [[ ! -f "$PACKAGE_JSON" ]]; then
	log_error "package.json not found at: $PACKAGE_JSON"
	exit 1
fi

log_info "[node] Updating $PACKAGE_JSON → $NEXT_VERSION"

# Update version field, preserving formatting
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

jq --arg v "$NEXT_VERSION" '.version = $v' "$PACKAGE_JSON" >"$TMPFILE"
mv "$TMPFILE" "$PACKAGE_JSON"
trap - EXIT

# Verify the write
ACTUAL=$(jq -r '.version' "$PACKAGE_JSON")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[node] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[node] $PACKAGE_JSON updated to $NEXT_VERSION"
