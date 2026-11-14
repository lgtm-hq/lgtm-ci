#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Ruby gem version files
#
# Updates VERSION = "..." in version.rb and rewrites the gem's own
# version in Gemfile.lock (never runs Bundler; see below, #1545).
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
: "${ECOSYSTEM_CONFIG_JSON:="{}"}"

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

# Rewrite only the gem's own spec under the PATH section whose remote is the
# gem's own directory (GEM_DIR below), plus the checksum-less CHECKSUMS line Bundler
# writes for a path gem; see rewrite-gemfile-lock.awk. A same-name spec under
# GEM or GIT (a published copy) and DEPENDENCIES stay as they are. This does
# NOT re-resolve transitive dependencies or refresh other lockfile metadata;
# for a version-only bump it is the change Bundler would make to this gem
# (issue #55 3.4).
#
# 'bundle lock' is deliberately not run here (#1545): Bundler evaluates the
# caller's Gemfile and *.gemspec as Ruby, and this job holds the caller's
# release App token (#1451). The rewrite was already the path taken
# wherever Bundler was absent.
#
# RubyGems reads '-' in a version as '.pre.' (Gem::Version), so a semver
# prerelease such as 1.2.0-rc.1 is locked as 1.2.0.pre.rc.1, as Bundler
# would write it.
# The gem's directory relative to Gemfile.lock, which Bundler writes as the
# PATH remote (`gemspec` -> `remote: .`, `gemspec path: "gems/demo"` ->
# `remote: gems/demo`): the part of the version.rb path before `lib/` (the
# gem root), else the nearest directory at or below that root holding
# <gem>.gemspec, else the lock's own directory. The search never climbs above
# the gem root, so a version.rb in one subtree cannot pair with a gemspec in
# another. Only a PATH section with that remote is accepted.
gem_dir_for() {
	local rb="${1#./}" dir root
	case "$rb" in
	lib/*) root="." ;;
	*/lib/*) root="${rb%%/lib/*}" ;;
	*) root=$(dirname "$rb") ;;
	esac
	dir=$(dirname "$rb")
	while :; do
		if [[ -f "${dir}/${GEM_NAME}.gemspec" ]]; then
			echo "$dir"
			return
		fi
		[[ "$dir" == "$root" || "$dir" == "." || "$dir" == "/" ]] && break
		dir=$(dirname "$dir")
	done
	echo "$root"
}
GEM_DIR=$(gem_dir_for "$VERSION_RB")

LOCK_VERSION="${NEXT_VERSION//-/.pre.}"
if [[ ! "$LOCK_VERSION" =~ ^[0-9A-Za-z]+(\.[0-9A-Za-z]+)*$ ]]; then
	echo "::error::[ruby] NEXT_VERSION '${NEXT_VERSION}' is not a RubyGems version" >&2
	exit 1
fi

log_info "[ruby] Updating $GEM_NAME version in Gemfile.lock → $LOCK_VERSION"
LOCK_TMP=$(mktemp "./.Gemfile.lock.XXXXXX")
LOCK_ERR=$(mktemp)
LOCK_RC=0
awk -v gem="$GEM_NAME" -v new_version="$LOCK_VERSION" -v gem_dir="$GEM_DIR" \
	-f "$SCRIPT_DIR/rewrite-gemfile-lock.awk" Gemfile.lock >"$LOCK_TMP" 2>"$LOCK_ERR" ||
	LOCK_RC=$?
LOCK_DETAIL=$(cat "$LOCK_ERR")
rm -f "$LOCK_ERR"
if [[ "$LOCK_RC" -ne 0 ]]; then
	rm -f "$LOCK_TMP"
	case "$LOCK_RC" in
	2)
		LOCK_REASON="it has no ${GEM_NAME} spec under a PATH section with"
		LOCK_REASON+=" 'remote: ${GEM_DIR}'"
		;;
	3)
		LOCK_REASON="${GEM_NAME} is locked only from${LOCK_DETAIL#only in:}, not from this"
		LOCK_REASON+=" checkout (PATH 'remote: ${GEM_DIR}'); a GEM or GIT entry is a"
		LOCK_REASON+=" published copy"
		;;
	4) LOCK_REASON="${GEM_NAME} has a non-RubyGems version:${LOCK_DETAIL#invalid version:}" ;;
	*) LOCK_REASON="awk exited ${LOCK_RC}: ${LOCK_DETAIL}" ;;
	esac
	echo "::error::[ruby] Cannot update Gemfile.lock: ${LOCK_REASON}. Gemfile.lock was" \
		"not changed." >&2
	exit 1
fi
mv "$LOCK_TMP" Gemfile.lock

log_success "[ruby] Gemfile.lock updated to $NEXT_VERSION"
