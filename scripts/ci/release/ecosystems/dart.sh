#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Dart version files
#
# Updates the version field in pubspec.yaml.
# Only runs if pubspec.yaml exists.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3)
#
# Optional (via ECOSYSTEM_CONFIG_JSON):
#   pubspec - Path to pubspec.yaml (default: ./pubspec.yaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:={}}"

PUBSPEC=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '.pubspec // "pubspec.yaml"')

if [[ ! -f "$PUBSPEC" ]]; then
	log_error "[dart] $PUBSPEC not found — skipping"
	exit 1
fi

log_info "[dart] Updating $PUBSPEC → $NEXT_VERSION"

write_file_atomic "$PUBSPEC" sed "s|^version: .*|version: $NEXT_VERSION|" "$PUBSPEC"

# Verify the write
ACTUAL=$(sed -n 's/^version: //p' "$PUBSPEC")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[dart] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[dart] $PUBSPEC updated to $NEXT_VERSION"
