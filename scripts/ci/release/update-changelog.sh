#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update CHANGELOG.md with new release entries
#
# Moves [Unreleased] entries into a new versioned section and
# resets the [Unreleased] section for future changes.
#
# Required environment variables:
#   VERSION - Release version (without v prefix)
#   CHANGELOG_BODY - Generated changelog content for this release
#
# Optional environment variables:
#   CHANGELOG_FILE - Path to CHANGELOG.md (default: CHANGELOG.md)
#   TAG_PREFIX - Prefix for version tags (default: v)
#   REPO_URL - Repository URL (default: auto-detected)
#   PUSH - Whether to commit and push the update (default: false)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${VERSION:?VERSION is required}"
: "${CHANGELOG_BODY:?CHANGELOG_BODY is required}"
: "${CHANGELOG_FILE:=CHANGELOG.md}"
: "${TAG_PREFIX:=v}"
: "${REPO_URL:=}"
: "${PUSH:=false}"

# Auto-detect repo URL
if [[ -z "$REPO_URL" ]]; then
	REPO_URL=$(git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|')
fi

CLEAN_VERSION="${VERSION#v}"
TAG_NAME="${TAG_PREFIX}${CLEAN_VERSION}"
RELEASE_DATE=$(date +%Y-%m-%d)

if [[ ! -f "$CHANGELOG_FILE" ]]; then
	log_error "CHANGELOG.md not found at: $CHANGELOG_FILE"
	exit 1
fi

log_info "Updating $CHANGELOG_FILE for version $CLEAN_VERSION"

# Build the new versioned section from the generated changelog body
NEW_SECTION="## [${CLEAN_VERSION}] - ${RELEASE_DATE}

${CHANGELOG_BODY}"

# Build the empty unreleased section
UNRELEASED_SECTION="## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security"

# Find the previous version tag for the comparison link
PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")

# Build the new comparison links
if [[ -n "$PREV_TAG" ]]; then
	VERSION_LINK="[${CLEAN_VERSION}]: ${REPO_URL}/compare/${PREV_TAG}...${TAG_NAME}"
else
	VERSION_LINK="[${CLEAN_VERSION}]: ${REPO_URL}/releases/tag/${TAG_NAME}"
fi
UNRELEASED_LINK="[Unreleased]: ${REPO_URL}/compare/${TAG_NAME}...HEAD"

# Read existing file
EXISTING=$(cat "$CHANGELOG_FILE")

# Replace the [Unreleased] section with fresh unreleased + new version
# Match from "## [Unreleased]" to the next "## [" or link references
UPDATED=$(echo "$EXISTING" | awk -v new_section="$NEW_SECTION" -v unreleased="$UNRELEASED_SECTION" -v unreleased_link="$UNRELEASED_LINK" -v version_link="$VERSION_LINK" '
BEGIN { in_unreleased=0; printed_replacement=0; in_links=0 }
/^## \[Unreleased\]/ {
	print unreleased
	print ""
	print new_section
	in_unreleased=1
	printed_replacement=1
	next
}
in_unreleased && /^## \[/ {
	in_unreleased=0
	print
	next
}
in_unreleased { next }
/^\[Unreleased\]:/ {
	print unreleased_link
	print version_link
	in_links=1
	next
}
in_links && /^\[/ {
	in_links=0
	print
	next
}
in_links { next }
{ print }
')

echo "$UPDATED" >"$CHANGELOG_FILE"

log_success "Updated $CHANGELOG_FILE with version $CLEAN_VERSION"

# Commit and push if requested
if [[ "$PUSH" == "true" ]]; then
	if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
		configure_git_ci_user
	fi
	git add "$CHANGELOG_FILE"
	git commit -m "docs: update CHANGELOG.md for ${CLEAN_VERSION}"
	git push origin HEAD
	log_success "Committed and pushed CHANGELOG.md update"
fi
