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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:={}}"

VERSION_SWIFT=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '."version-swift" // ""')

# Auto-detect Version.swift if not configured
if [[ -z "$VERSION_SWIFT" ]]; then
	MATCHES=()
	while IFS= read -r match; do
		MATCHES+=("$match")
	done < <(find . -path '*/Sources/*/Version.swift' 2>/dev/null)
	if [[ ${#MATCHES[@]} -eq 0 ]]; then
		log_error "[swift] No Version.swift found and none configured"
		exit 1
	fi
	if [[ ${#MATCHES[@]} -gt 1 ]]; then
		log_error "[swift] Multiple Version.swift files found — set 'version-swift' in config:"
		for m in "${MATCHES[@]}"; do
			log_error "  $m"
		done
		exit 1
	fi
	VERSION_SWIFT="${MATCHES[0]}"
	log_info "[swift] Auto-detected: $VERSION_SWIFT"
fi

if [[ ! -f "$VERSION_SWIFT" ]]; then
	log_error "[swift] Version.swift not found at: $VERSION_SWIFT"
	exit 1
fi

# Count candidate lines — we only update if exactly one matches so
# we never silently pick the wrong constant in a file with multiple
# (e.g., "static let name = ..." + "static let version = ..."). Authors
# wanting different behavior should set 'version-swift' in config to
# point at a file containing exactly one candidate.
CANDIDATE_COUNT=$(awk '/static let [a-zA-Z_][a-zA-Z0-9_]* = "/ { n++ } END { print n + 0 }' "$VERSION_SWIFT")
if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
	log_error "[swift] No 'static let <ident> = \"...\"' constant found in $VERSION_SWIFT"
	exit 1
fi
if [[ "$CANDIDATE_COUNT" -gt 1 ]]; then
	log_error "[swift] $VERSION_SWIFT contains $CANDIDATE_COUNT candidate constants — point 'version-swift' at a file with exactly one:"
	awk '/static let [a-zA-Z_][a-zA-Z0-9_]* = "/ { print "  " $0 }' "$VERSION_SWIFT" >&2
	exit 1
fi

log_info "[swift] Updating $VERSION_SWIFT → $NEXT_VERSION"

# Update the single candidate constant (matches patterns like:
#   public static let string = "1.2.3"
#   static let version_string = "1.2.3"
write_file_atomic "$VERSION_SWIFT" awk -v ver="$NEXT_VERSION" '
!done && /static let [a-zA-Z_][a-zA-Z0-9_]* = "/ {
	sub(/"[^"]*"/, "\"" ver "\"")
	done = 1
}
{ print }
' "$VERSION_SWIFT"

# Verify the write — use the same strict-identifier regex as the
# replacement above so both operations target the same (single) line.
ACTUAL=$(awk -F'"' '/static let [a-zA-Z_][a-zA-Z0-9_]* = "/ {print $2; exit}' "$VERSION_SWIFT")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[swift] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[swift] $VERSION_SWIFT updated to $NEXT_VERSION"
