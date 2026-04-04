#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Kotlin/Gradle version files
#
# Updates the version field in build.gradle.kts via sed.
# Only runs if build.gradle.kts exists.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3)
#
# Optional (via ECOSYSTEM_CONFIG_JSON):
#   gradle - Path to build.gradle.kts (default: ./build.gradle.kts)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:={}}"

GRADLE=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '.gradle // "build.gradle.kts"')

if [[ ! -f "$GRADLE" ]]; then
	log_info "[kotlin] $GRADLE not found — skipping"
	exit 0
fi

log_info "[kotlin] Updating $GRADLE → $NEXT_VERSION"

sed -i "s/^version = \"[^\"]*\"/version = \"$NEXT_VERSION\"/" "$GRADLE"

# Verify the write
ACTUAL=$(grep -oP '^version = "\K[^"]+' "$GRADLE" || true)
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[kotlin] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[kotlin] $GRADLE updated to $NEXT_VERSION"
