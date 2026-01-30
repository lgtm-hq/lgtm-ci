#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Calculate next semantic version based on conventional commits
#
# Required environment variables:
#   None (uses git history)
#
# Optional environment variables:
#   MAX_BUMP - Maximum bump type allowed: major, minor, patch (default: major)
#   FROM_REF - Reference to start from (default: latest tag)
#   TO_REF - Reference to end at (default: HEAD)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/release.sh
source "$LIB_DIR/release.sh"

: "${MAX_BUMP:=major}"
: "${FROM_REF:=}"
: "${TO_REF:=HEAD}"

# Get from_ref if not specified
if [[ -z "$FROM_REF" ]]; then
	FROM_REF=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
fi

log_info "Analyzing commits from '${FROM_REF:-beginning}' to '$TO_REF'"

# Get current version
CURRENT_VERSION=""
if [[ -n "$FROM_REF" ]]; then
	CURRENT_VERSION="${FROM_REF#v}"
else
	CURRENT_VERSION="0.0.0"
fi

log_info "Current version: $CURRENT_VERSION"

# Analyze commits
BUMP_TYPE=$(analyze_commits_for_bump "$FROM_REF" "$TO_REF")
log_info "Detected bump type: $BUMP_TYPE"

if [[ "$BUMP_TYPE" == "none" ]]; then
	log_info "No releasable commits found"
	NEXT_VERSION=""
	RELEASE_NEEDED="false"
else
	# Clamp bump type
	ORIGINAL_BUMP="$BUMP_TYPE"
	BUMP_TYPE=$(clamp_bump "$BUMP_TYPE" "$MAX_BUMP")
	if [[ "$ORIGINAL_BUMP" != "$BUMP_TYPE" ]]; then
		log_info "Bump type clamped from $ORIGINAL_BUMP to $BUMP_TYPE (max: $MAX_BUMP)"
	fi

	# Calculate next version
	NEXT_VERSION=$(bump_version "$CURRENT_VERSION" "$BUMP_TYPE")
	RELEASE_NEEDED="true"
	log_success "Next version: $NEXT_VERSION"
fi

# Output for GitHub Actions
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "current-version=$CURRENT_VERSION"
		echo "next-version=$NEXT_VERSION"
		echo "bump-type=$BUMP_TYPE"
		echo "release-needed=$RELEASE_NEEDED"
	} >>"$GITHUB_OUTPUT"
fi

# Also output to stdout for local testing
echo "current-version=$CURRENT_VERSION"
echo "next-version=$NEXT_VERSION"
echo "bump-type=$BUMP_TYPE"
echo "release-needed=$RELEASE_NEEDED"
