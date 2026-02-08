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

if [[ -z "$REPO_URL" ]]; then
	log_error "REPO_URL could not be detected and was not provided (needed for ${TAG_NAME} comparison links)"
	exit 1
fi
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

# Find the previous semver tag for the comparison link (skip floating tags)
PREV_TAG=$(git tag --merged HEAD^ --sort=-v:refname |
	grep -E "^${TAG_PREFIX}[0-9]+\.[0-9]+\.[0-9]+" |
	head -n1) || true
PREV_TAG="${PREV_TAG:-}"

# Build the new comparison links
if [[ -n "$PREV_TAG" ]]; then
	VERSION_LINK="[${CLEAN_VERSION}]: ${REPO_URL}/compare/${PREV_TAG}...${TAG_NAME}"
else
	VERSION_LINK="[${CLEAN_VERSION}]: ${REPO_URL}/releases/tag/${TAG_NAME}"
fi
UNRELEASED_LINK="[Unreleased]: ${REPO_URL}/compare/${TAG_NAME}...HEAD"

# Update changelog via awk, reading the file directly and writing to a temp file
TMPFILE=$(mktemp "${CHANGELOG_FILE}.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

export NEW_SECTION UNRELEASED_SECTION UNRELEASED_LINK VERSION_LINK

awk '
BEGIN { in_unreleased=0; in_links=0 }
/^## \[Unreleased\]/ {
	print ENVIRON["UNRELEASED_SECTION"]
	print ""
	print ENVIRON["NEW_SECTION"]
	in_unreleased=1
	next
}
in_unreleased && /^## \[/ {
	in_unreleased=0
	print
	next
}
in_unreleased { next }
/^\[Unreleased\]:/ {
	print ENVIRON["UNRELEASED_LINK"]
	print ENVIRON["VERSION_LINK"]
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
' "$CHANGELOG_FILE" >"$TMPFILE"

chmod --reference="$CHANGELOG_FILE" "$TMPFILE"
mv "$TMPFILE" "$CHANGELOG_FILE"
trap - EXIT

log_success "Updated $CHANGELOG_FILE with version $CLEAN_VERSION"

# Commit and push if requested
if [[ "$PUSH" == "true" ]]; then
	# Resolve target branch (handles detached HEAD in CI)
	TARGET_BRANCH="${GITHUB_REF_NAME:-}"
	if [[ -z "$TARGET_BRANCH" ]]; then
		TARGET_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
	fi
	if [[ -z "$TARGET_BRANCH" ]]; then
		log_error "Could not determine target branch for push (detached HEAD with no GITHUB_REF_NAME)"
		exit 1
	fi

	if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
		configure_git_ci_user
	fi
	git add "$CHANGELOG_FILE"
	git commit -m "docs: update CHANGELOG.md for ${CLEAN_VERSION}"
	git push origin HEAD:refs/heads/"$TARGET_BRANCH"
	log_success "Committed and pushed CHANGELOG.md update to $TARGET_BRANCH"
fi
