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
#   PUSH_MAX_ATTEMPTS - Push attempts before giving up (default: 3)
#   PUSH_RETRY_DELAY - Base seconds between push attempts (default: 5)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
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
: "${PUSH_MAX_ATTEMPTS:=3}"
: "${PUSH_RETRY_DELAY:=5}"

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
git tag -fa "$FLOATING_TAG" "${TAG}^{}" -m "Release ${FLOATING_TAG} (latest: ${TAG})"
log_success "Updated local tag: $FLOATING_TAG -> $TAG"

# Push if requested
if [[ "$PUSH" == "true" ]]; then
	TARGET_COMMIT=$(git rev-parse "${FLOATING_TAG}^{}")

	# Reruns must converge: skip the push when the remote floating tag
	# already dereferences to the target commit.
	REMOTE_REFS=$(git ls-remote origin "refs/tags/${FLOATING_TAG}" "refs/tags/${FLOATING_TAG}^{}" 2>/dev/null || true)
	REMOTE_COMMIT=$(printf '%s\n' "$REMOTE_REFS" | awk -v ref="refs/tags/${FLOATING_TAG}^{}" '$2 == ref {print $1}')
	if [[ -z "$REMOTE_COMMIT" ]]; then
		REMOTE_COMMIT=$(printf '%s\n' "$REMOTE_REFS" | awk -v ref="refs/tags/${FLOATING_TAG}" '$2 == ref {print $1}')
	fi

	if [[ "$REMOTE_COMMIT" == "$TARGET_COMMIT" ]]; then
		log_info "Remote floating tag $FLOATING_TAG already points at $TARGET_COMMIT; skipping push"
	else
		log_info "Pushing floating tag to origin..."
		# GitHub occasionally rejects ref updates transiently (e.g.
		# "remote: fatal error in commit_refs"); retry before failing.
		ATTEMPT=1
		until git push origin "$FLOATING_TAG" --force; do
			if ((ATTEMPT >= PUSH_MAX_ATTEMPTS)); then
				log_error "Failed to push floating tag $FLOATING_TAG after $PUSH_MAX_ATTEMPTS attempts"
				exit 1
			fi
			log_warning "Push failed (attempt $ATTEMPT/$PUSH_MAX_ATTEMPTS); retrying in $((ATTEMPT * PUSH_RETRY_DELAY))s..."
			sleep $((ATTEMPT * PUSH_RETRY_DELAY))
			ATTEMPT=$((ATTEMPT + 1))
		done
		log_success "Pushed floating tag: $FLOATING_TAG"
	fi
fi

# Output for GitHub Actions
set_github_output "floating-tag" "$FLOATING_TAG"
set_github_output "source-tag" "$TAG"

echo "floating-tag=$FLOATING_TAG"
echo "source-tag=$TAG"
