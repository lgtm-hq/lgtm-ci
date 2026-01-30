#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Release automation library aggregator
#
# Sources all release-related libraries for convenient single-file import.
# Usage: source "scripts/ci/lib/release.sh"

# Guard against multiple sourcing
[[ -n "${_RELEASE_LOADED:-}" ]] && return 0
readonly _RELEASE_LOADED=1

# Get the directory of this script
RELEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all release sub-libraries
# shellcheck source=./release/version.sh
source "$RELEASE_LIB_DIR/release/version.sh"

# shellcheck source=./release/conventional.sh
source "$RELEASE_LIB_DIR/release/conventional.sh"

# shellcheck source=./release/changelog.sh
source "$RELEASE_LIB_DIR/release/changelog.sh"

# ============================================================================
# High-level release functions
# ============================================================================

# Determine next version based on commits since last tag
# Usage: determine_next_version [max_bump]
# Output: next version string
determine_next_version() {
	local max_bump="${1:-major}"

	# Get latest tag
	local latest_tag
	latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

	# Get current version
	local current_version
	if [[ -n "$latest_tag" ]]; then
		current_version="${latest_tag#v}"
	else
		# No tags, start from 0.0.0
		current_version="0.0.0"
	fi

	# Analyze commits for bump type
	local bump_type
	bump_type=$(analyze_commits_for_bump "$latest_tag" "HEAD")

	if [[ "$bump_type" == "none" ]]; then
		echo ""
		return 1
	fi

	# Clamp to max bump
	bump_type=$(clamp_bump "$bump_type" "$max_bump")

	# Calculate next version
	bump_version "$current_version" "$bump_type"
}

# Create a release (tag + changelog)
# Usage: create_release "1.0.0" [push]
create_release() {
	local version="${1:-}"
	local push="${2:-false}"

	if [[ -z "$version" ]]; then
		echo "Version required" >&2
		return 1
	fi

	# Ensure version doesn't have v prefix for internal use
	local clean_version="${version#v}"
	local tag_name="v${clean_version}"

	# Get latest tag for changelog
	local latest_tag
	latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

	# Generate changelog
	local changelog
	changelog=$(generate_changelog "$latest_tag" "HEAD" "$clean_version")

	# Create annotated tag
	git tag -a "$tag_name" -m "Release ${tag_name}"$'\n\n'"${changelog}"

	echo "Created tag: $tag_name"

	if [[ "$push" == "true" ]]; then
		git push origin "$tag_name"
		echo "Pushed tag: $tag_name"
	fi

	echo "$tag_name"
}

# Check if release is needed
# Usage: should_release [from_ref]
should_release() {
	local from_ref="${1:-}"

	if [[ -z "$from_ref" ]]; then
		from_ref=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
	fi

	has_releasable_commits "$from_ref" "HEAD"
}

# Get release summary
# Usage: get_release_summary
get_release_summary() {
	local latest_tag
	latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

	echo "Latest tag: ${latest_tag:-none}"

	local bump
	bump=$(analyze_commits_for_bump "$latest_tag" "HEAD")
	echo "Bump type: $bump"

	if [[ "$bump" != "none" ]]; then
		local next
		next=$(determine_next_version)
		echo "Next version: $next"
	fi

	echo ""
	count_commits_by_type "$latest_tag" "HEAD"
}
