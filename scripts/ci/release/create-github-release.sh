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
#   FILE_PATTERNS - Newline-separated glob patterns (used by reusable workflows)
#   REPO - Repository in owner/repo format (default: GITHUB_REPOSITORY or git remote)

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
# shellcheck source=../lib/release/assets.sh
source "$LIB_DIR/release/assets.sh"

: "${TAG:?TAG is required}"
: "${TITLE:=$TAG}"
: "${BODY:=}"
: "${DRAFT:=false}"
: "${PRERELEASE:=false}"
: "${GENERATE_NOTES:=false}"
: "${FILES:=}"
: "${FILE_PATTERNS:=}"
: "${REPO:=}"

# Check for gh CLI
if ! command -v gh &>/dev/null; then
	log_error "GitHub CLI (gh) is required but not found"
	exit 1
fi

# Get repo from git remote if not specified
if [[ -z "$REPO" ]]; then
	if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
		REPO="$GITHUB_REPOSITORY"
	elif REMOTE_URL=$(git remote get-url origin 2>/dev/null); then
		if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+/[^/]+) ]]; then
			REPO="${BASH_REMATCH[1]}"
			REPO="${REPO%.git}"
		fi
	fi
	if [[ -z "$REPO" ]]; then
		log_error "Could not determine repository; set REPO or GITHUB_REPOSITORY"
		exit 1
	fi
fi

log_info "Creating GitHub release for $TAG in $REPO"

# A release that already exists for this tag is a rerun of a partially failed
# release job, not a collision — skip creation so the job can converge
# (idempotent, matching create-tag.sh). The existing release is queried rather
# than string-matching `gh release create` stderr, so every other create
# failure still exits non-zero.
RELEASE_EXISTS=false
if EXISTING_RELEASE_URL=$(gh release view "$TAG" --repo "$REPO" --json url --jq '.url' 2>/dev/null) &&
	[[ -n "$EXISTING_RELEASE_URL" ]]; then
	log_info "Release $TAG already exists at $EXISTING_RELEASE_URL; skipping creation"
	RELEASE_EXISTS=true
	RELEASE_URL="$EXISTING_RELEASE_URL"
fi

# Resolve the requested assets before branching: both paths need them. A
# previous attempt can die between creating the release and finishing its
# uploads, so "the release exists" does not imply "its assets are there".
ASSET_FILES=()
if [[ -n "$FILE_PATTERNS" ]]; then
	release_collect_asset_files "$FILE_PATTERNS"
	if ((${#RELEASE_ASSET_FILES[@]} == 0)); then
		log_error "No release assets matched FILE_PATTERNS"
		exit 1
	fi
	ASSET_FILES=("${RELEASE_ASSET_FILES[@]}")
elif [[ -n "$FILES" ]]; then
	# shellcheck disable=SC2086 # Word splitting intended for space-separated FILES
	for file in $FILES; do
		if [[ -f "$file" ]]; then
			ASSET_FILES+=("$file")
		else
			log_warn "File not found, skipping: $file"
		fi
	done
fi

if [[ "$RELEASE_EXISTS" != "true" ]]; then
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
	if ((${#ASSET_FILES[@]} > 0)); then
		GH_ARGS+=("${ASSET_FILES[@]}")
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
elif ((${#ASSET_FILES[@]} > 0)); then
	# The release object survived, but the attempt that made it may have died
	# mid-upload. Re-upload every requested asset; --clobber makes an asset that
	# did land a no-op overwrite rather than a "already exists" failure, so the
	# rerun converges on the complete asset set either way.
	log_info "Uploading ${#ASSET_FILES[@]} asset(s) to existing release $TAG"
	if ! gh release upload "$TAG" --repo "$REPO" --clobber "${ASSET_FILES[@]}"; then
		log_error "Failed to upload assets to existing release $TAG"
		exit 1
	fi
	log_success "Uploaded assets to existing release: $RELEASE_URL"
fi

# Get release info
RELEASE_ID=$(gh release view "$TAG" --repo "$REPO" --json id --jq '.id' 2>/dev/null || echo "")

# Output for GitHub Actions
set_github_output "release-url" "$RELEASE_URL"
set_github_output "release-id" "$RELEASE_ID"
set_github_output "tag" "$TAG"

echo "release-url=$RELEASE_URL"
echo "release-id=$RELEASE_ID"
