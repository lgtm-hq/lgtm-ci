#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Ruby gem version files
#
# Updates VERSION = "..." in version.rb and regenerates Gemfile.lock
# via bundle lock (with regex fallback if bundle is unavailable).
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3)
#
# Optional (via ECOSYSTEM_CONFIG_JSON):
#   gem         - Gem name for Gemfile.lock update (default: auto-detected)
#   version-rb  - Path to version.rb (default: auto-detected from gemspec)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:={}}"

GEM_NAME=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '.gem // ""')
VERSION_RB=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '."version-rb" // ""')

# =============================================================================
# Auto-detect gem name from gemspec if not configured
# =============================================================================

if [[ -z "$GEM_NAME" ]]; then
	GEMSPEC=$(find . -maxdepth 1 -name '*.gemspec' -print -quit 2>/dev/null || true)
	if [[ -n "$GEMSPEC" ]]; then
		GEM_NAME=$(basename "$GEMSPEC" .gemspec)
		log_info "[ruby] Auto-detected gem name: $GEM_NAME"
	else
		log_error "[ruby] No gem name configured and no .gemspec found"
		exit 1
	fi
fi

# =============================================================================
# Update version.rb
# =============================================================================

if [[ -z "$VERSION_RB" ]]; then
	# Standard gem layout: lib/<gem>/version.rb
	# Convert dashes to path separators for hyphenated gem names
	GEM_PATH="${GEM_NAME//-//}"
	VERSION_RB="lib/${GEM_PATH}/version.rb"
fi

if [[ ! -f "$VERSION_RB" ]]; then
	log_error "[ruby] version.rb not found at: $VERSION_RB"
	exit 1
fi

log_info "[ruby] Updating $VERSION_RB → $NEXT_VERSION"

sed "s/VERSION = \"[^\"]*\"/VERSION = \"$NEXT_VERSION\"/" "$VERSION_RB" |
	write_file_atomic "$VERSION_RB"

# Verify the write
ACTUAL=$(awk -F'"' '/VERSION =/ {print $2; exit}' "$VERSION_RB")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[ruby] version.rb verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[ruby] $VERSION_RB updated to $NEXT_VERSION"

# =============================================================================
# Update Gemfile.lock
# =============================================================================

if [[ ! -f "Gemfile.lock" ]]; then
	log_info "[ruby] No Gemfile.lock found — skipping"
	exit 0
fi

if command -v bundle >/dev/null 2>&1; then
	log_info "[ruby] Regenerating Gemfile.lock via bundle lock..."
	bundle lock --update "$GEM_NAME" 2>&1 | tail -5
else
	log_warn "[ruby] bundle not found — using regex fallback for Gemfile.lock"
	# Replace version in PATH spec and CHECKSUMS sections
	sed "s/\(^\|[[:space:]]\)${GEM_NAME} ([0-9][0-9.]*[0-9])/\1${GEM_NAME} (${NEXT_VERSION})/g" \
		Gemfile.lock | write_file_atomic Gemfile.lock
fi

# Verify Gemfile.lock contains the updated version
if ! grep -qE "(^|[[:space:]])${GEM_NAME} \(${NEXT_VERSION}\)" Gemfile.lock; then
	log_error "[ruby] Gemfile.lock verification failed: ${GEM_NAME} (${NEXT_VERSION}) not found"
	exit 1
fi

log_success "[ruby] Gemfile.lock updated to $NEXT_VERSION"
