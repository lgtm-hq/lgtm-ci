#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update major version floating tag to point to latest release
#
# Required environment variables:
#   TAG - Full semver tag (e.g., v1.2.3)
#
# Optional environment variables:
#   TAG_PREFIX - Prefix for tag name (default: v)
#   PUSH - Whether to push the tag (default: false)

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

: "${TAG:?TAG is required}"
: "${TAG_PREFIX:=v}"
: "${PUSH:=false}"

# Extract version from tag
CLEAN_VERSION="${TAG#"$TAG_PREFIX"}"

if ! parse_version "$CLEAN_VERSION"; then
	log_error "Invalid semver tag: $TAG"
	exit 1
fi

FLOATING_TAG="${TAG_PREFIX}${MAJOR}"

log_info "Updating floating tag: $FLOATING_TAG -> $TAG"

# Configure git user for CI
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
	configure_git_ci_user
fi

# Force-update the floating tag locally
git tag -fa "$FLOATING_TAG" "$TAG" -m "Release ${FLOATING_TAG} (latest: ${TAG})"
log_success "Updated local tag: $FLOATING_TAG -> $TAG"

# Push if requested
if [[ "$PUSH" == "true" ]]; then
	log_info "Pushing floating tag to origin..."
	git push origin "$FLOATING_TAG" --force
	log_success "Pushed floating tag: $FLOATING_TAG"
fi

# Output for GitHub Actions
set_github_output "floating-tag" "$FLOATING_TAG"
set_github_output "source-tag" "$TAG"

echo "floating-tag=$FLOATING_TAG"
echo "source-tag=$TAG"
