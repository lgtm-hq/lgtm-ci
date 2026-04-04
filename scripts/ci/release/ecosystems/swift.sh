#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Swift version files
#
# Updates the version string in Version.swift. Only updates existing
# files — does not create new ones.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3)
#
# Optional (via ECOSYSTEM_CONFIG_JSON):
#   version-swift - Path to Version.swift (default: auto-detected)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:={}}"

VERSION_SWIFT=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '."version-swift" // ""')

# Auto-detect Version.swift if not configured
if [[ -z "$VERSION_SWIFT" ]]; then
	VERSION_SWIFT=$(find . -path '*/Sources/*/Version.swift' -print -quit 2>/dev/null || true)
	if [[ -z "$VERSION_SWIFT" ]]; then
		log_error "[swift] No Version.swift found and none configured"
		exit 1
	fi
	log_info "[swift] Auto-detected: $VERSION_SWIFT"
fi

if [[ ! -f "$VERSION_SWIFT" ]]; then
	log_error "[swift] Version.swift not found at: $VERSION_SWIFT"
	exit 1
fi

log_info "[swift] Updating $VERSION_SWIFT → $NEXT_VERSION"

# Update the version string constant (matches patterns like:
#   public static let string = "1.2.3"
#   static let version_string = "1.2.3"
# Uses [a-zA-Z_][a-zA-Z0-9_]* to match valid Swift identifiers.
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
sed "s/\(static let [a-zA-Z_][a-zA-Z0-9_]* = \"\)[^\"]*\"/\1${NEXT_VERSION}\"/" \
	"$VERSION_SWIFT" >"$TMPFILE"
mv "$TMPFILE" "$VERSION_SWIFT"
trap - EXIT

# Verify the write (take first match only)
ACTUAL=$(awk -F'"' '/static let .* = "/ {print $2; exit}' "$VERSION_SWIFT")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[swift] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[swift] $VERSION_SWIFT updated to $NEXT_VERSION"
