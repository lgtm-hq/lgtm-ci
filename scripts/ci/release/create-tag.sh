#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Create a git tag for release
#
# Required environment variables:
#   VERSION - Version to tag (with or without v prefix)
#
# Optional environment variables:
#   TAG_PREFIX - Prefix for tag (default: v)
#   MESSAGE - Tag message (default: auto-generated from changelog)
#   PUSH - Whether to push the tag (default: false)
#   FROM_REF - Reference for changelog generation (default: latest tag)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/release.sh
source "$LIB_DIR/release.sh"

: "${VERSION:?VERSION is required}"
: "${TAG_PREFIX:=v}"
: "${MESSAGE:=}"
: "${PUSH:=false}"
: "${FROM_REF:=}"

# Clean version (remove v prefix if present, we'll add TAG_PREFIX)
CLEAN_VERSION="${VERSION#v}"
TAG_NAME="${TAG_PREFIX}${CLEAN_VERSION}"

log_info "Creating tag: $TAG_NAME"

# Check if tag already exists
if git rev-parse --verify --quiet "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
	log_error "Tag $TAG_NAME already exists"
	exit 1
fi

# Get from_ref if not specified
if [[ -z "$FROM_REF" ]]; then
	FROM_REF=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
fi

# Generate message if not provided
if [[ -z "$MESSAGE" ]]; then
	log_info "Generating changelog for tag message..."
	CHANGELOG=$(generate_changelog "$FROM_REF" "HEAD" "$CLEAN_VERSION" "full")
	MESSAGE="Release ${TAG_NAME}"$'\n\n'"${CHANGELOG}"
fi

# Configure git user for CI
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
	configure_git_ci_user
fi

# Create annotated tag
git tag -a "$TAG_NAME" -m "$MESSAGE"
log_success "Created tag: $TAG_NAME"

# Get tag SHA
TAG_SHA=$(git rev-parse "$TAG_NAME")
COMMIT_SHA=$(git rev-parse HEAD)

# Push if requested
if [[ "$PUSH" == "true" ]]; then
	log_info "Pushing tag to origin..."
	git push origin "$TAG_NAME"
	log_success "Pushed tag: $TAG_NAME"
fi

# Output for GitHub Actions
set_github_output "tag-name" "$TAG_NAME"
set_github_output "tag-sha" "$TAG_SHA"
set_github_output "commit-sha" "$COMMIT_SHA"
set_github_output "version" "$CLEAN_VERSION"

echo "tag-name=$TAG_NAME"
echo "tag-sha=$TAG_SHA"
echo "commit-sha=$COMMIT_SHA"
