#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Create a GitHub release
#
# Required environment variables:
#   TAG - Tag name for the release
#
# Optional environment variables:
#   TITLE - Release title (default: tag name)
#   BODY - Release body/notes (default: auto-generated)
#   DRAFT - Create as draft (default: false)
#   PRERELEASE - Mark as prerelease (default: false)
#   GENERATE_NOTES - Use GitHub's auto-generated notes (default: false)
#   FILES - Space-separated list of files to attach
#   REPO - Repository in owner/repo format (default: from git remote)

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
: "${TITLE:=$TAG}"
: "${BODY:=}"
: "${DRAFT:=false}"
: "${PRERELEASE:=false}"
: "${GENERATE_NOTES:=false}"
: "${FILES:=}"
: "${REPO:=}"

# Check for gh CLI
if ! command -v gh &>/dev/null; then
	log_error "GitHub CLI (gh) is required but not found"
	exit 1
fi

# Get repo from git remote if not specified
if [[ -z "$REPO" ]]; then
	REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
	if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+/[^/]+) ]]; then
		REPO="${BASH_REMATCH[1]}"
		REPO="${REPO%.git}"
	else
		log_error "Could not determine repository from git remote"
		exit 1
	fi
fi

log_info "Creating GitHub release for $TAG in $REPO"

# Build gh release create command
GH_ARGS=("release" "create" "$TAG")
GH_ARGS+=("--repo" "$REPO")
GH_ARGS+=("--title" "$TITLE")

if [[ "$DRAFT" == "true" ]]; then
	GH_ARGS+=("--draft")
fi

if [[ "$PRERELEASE" == "true" ]]; then
	GH_ARGS+=("--prerelease")
fi

if [[ "$GENERATE_NOTES" == "true" ]]; then
	GH_ARGS+=("--generate-notes")
elif [[ -n "$BODY" ]]; then
	GH_ARGS+=("--notes" "$BODY")
else
	# Generate body from changelog
	FROM_REF=$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || echo "")
	CHANGELOG=$(generate_release_notes "$FROM_REF" "$TAG" "${TAG#v}")
	GH_ARGS+=("--notes" "$CHANGELOG")
fi

# Add files if specified
if [[ -n "$FILES" ]]; then
	# shellcheck disable=SC2086 # Word splitting intended for FILES
	for file in $FILES; do
		if [[ -f "$file" ]]; then
			GH_ARGS+=("$file")
		else
			log_warn "File not found, skipping: $file"
		fi
	done
fi

# Create release
log_info "Running: gh ${GH_ARGS[*]}"
GH_STDERR=$(mktemp)
trap 'rm -f "$GH_STDERR"' EXIT

if RELEASE_URL=$(gh "${GH_ARGS[@]}" 2>"$GH_STDERR"); then
	log_success "Created release: $RELEASE_URL"
	# Log any warnings from stderr
	if [[ -s "$GH_STDERR" ]]; then
		log_warn "gh stderr: $(cat "$GH_STDERR")"
	fi
else
	log_error "Failed to create release"
	if [[ -s "$GH_STDERR" ]]; then
		log_error "$(cat "$GH_STDERR")"
	fi
	exit 1
fi

# Get release info
RELEASE_ID=$(gh release view "$TAG" --repo "$REPO" --json id --jq '.id' 2>/dev/null || echo "")

# Output for GitHub Actions
set_github_output "release-url" "$RELEASE_URL"
set_github_output "release-id" "$RELEASE_ID"
set_github_output "tag" "$TAG"

echo "release-url=$RELEASE_URL"
echo "release-id=$RELEASE_ID"
