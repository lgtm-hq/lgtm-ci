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
	GEMSPECS=()
	while IFS= read -r spec; do
		GEMSPECS+=("$spec")
	done < <(find . -maxdepth 1 -name '*.gemspec' 2>/dev/null)

	if [[ ${#GEMSPECS[@]} -eq 0 ]]; then
		log_error "[ruby] No gem name configured and no .gemspec found"
		exit 1
	fi
	if [[ ${#GEMSPECS[@]} -gt 1 ]]; then
		log_error "[ruby] Multiple .gemspec files found — set 'gem' in config:"
		for spec in "${GEMSPECS[@]}"; do
			log_error "  $spec"
		done
		exit 1
	fi
	GEM_NAME=$(basename "${GEMSPECS[0]}" .gemspec)
	log_info "[ruby] Auto-detected gem name: $GEM_NAME"
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

write_file_atomic "$VERSION_RB" \
	sed -E "s/^([[:space:]]*)VERSION[[:space:]]*=[[:space:]]*\"[^\"]*\"/\\1VERSION = \"$NEXT_VERSION\"/" "$VERSION_RB"

# Verify the write — use the same anchored strict pattern as the sed
# above so comments or nested keys containing "VERSION =" aren't
# accidentally picked up.
ACTUAL=$(awk -F'"' '/^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*"/ {print $2; exit}' "$VERSION_RB")
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
	# Regex fallback per issue #55 3.4 — for environments where Bundler
	# isn't available (e.g., some CI images or cross-repo callers that
	# don't install ruby toolchain). This ONLY rewrites the gem's own
	# version strings in PATH specs and CHECKSUMS sections; it does NOT
	# re-resolve transitive dependencies or refresh other lockfile
	# metadata. Callers that need a fully-resolved lock should ensure
	# Bundler is on PATH so the primary 'bundle lock --update' path runs.
	log_warn "[ruby] bundle not found — using regex fallback for Gemfile.lock"
	log_warn "[ruby] Fallback does not refresh transitive dependencies"
	# Escape regex metacharacters in GEM_NAME for safe use in sed/grep
	# patterns (handles gems with dots or other special chars).
	ESC_GEM_NAME=$(printf '%s' "$GEM_NAME" | sed 's/[][\\.*^$/]/\\&/g')
	write_file_atomic Gemfile.lock \
		sed -E "s/(^|[[:space:]])${ESC_GEM_NAME} \\([0-9][0-9.]*[0-9]\\)/\\1${GEM_NAME} (${NEXT_VERSION})/g" \
		Gemfile.lock
fi

# Verify Gemfile.lock contains the updated version. Escape both the gem
# name and NEXT_VERSION for regex safety — NEXT_VERSION contains dots
# (regex metacharacters) that would otherwise allow false positives.
ESC_GEM_NAME=${ESC_GEM_NAME:-$(printf '%s' "$GEM_NAME" | sed 's/[][\\.*^$/]/\\&/g')}
ESC_NEXT_VERSION=$(printf '%s' "$NEXT_VERSION" | sed 's/[][\\.*^$/]/\\&/g')
if ! grep -qE "(^|[[:space:]])${ESC_GEM_NAME} \(${ESC_NEXT_VERSION}\)" Gemfile.lock; then
	log_error "[ruby] Gemfile.lock verification failed: ${GEM_NAME} (${NEXT_VERSION}) not found"
	exit 1
fi

log_success "[ruby] Gemfile.lock updated to $NEXT_VERSION"
