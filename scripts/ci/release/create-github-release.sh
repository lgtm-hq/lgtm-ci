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
#   CHECKSUMS - Attach a SHA256SUMS manifest of the assets; one already among
#               the assets is attached as is, otherwise one is written next to
#               them (default: false; the reusable passes true)
#   ARTIFACT_PATH - Directory the manifest is written into when generated
#                   (default: the first asset's directory)
#   IMMUTABLE_ASSETS - On a rerun, never overwrite a published asset whose
#                      bytes differ from the local file: same digest is a
#                      no-op, a different digest fails with the recovery rule
#                      (default: false; the reusable passes true)

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
: "${CHECKSUMS:=false}"
: "${ARTIFACT_PATH:=}"
: "${IMMUTABLE_ASSETS:=false}"

# sha256 of a local file, lowercase hex, portable across coreutils and BSD.
release_local_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

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

# SHA256SUMS: the manifest a verifier runs `sha256sum --check` against
# (release-security policy, section 1). One shipped inside the artifact (the
# Python build reusable writes it) is attached as is; otherwise one is written
# beside the assets from the assets themselves. The manifest never lists
# itself.
if [[ "$CHECKSUMS" == "true" && ${#ASSET_FILES[@]} -gt 0 ]]; then
	have_manifest=false
	for file in "${ASSET_FILES[@]}"; do
		if [[ "$(basename "$file")" == "SHA256SUMS" ]]; then
			have_manifest=true
			break
		fi
	done
	if [[ "$have_manifest" == "true" ]]; then
		log_info "Attaching the SHA256SUMS manifest shipped with the assets"
	else
		manifest_dir="${ARTIFACT_PATH:-$(dirname "${ASSET_FILES[0]}")}"
		manifest="${manifest_dir}/SHA256SUMS"
		: >"$manifest"
		for file in "${ASSET_FILES[@]}"; do
			printf '%s  %s\n' "$(release_local_sha256 "$file")" "$(basename "$file")" >>"$manifest"
		done
		ASSET_FILES+=("$manifest")
		log_info "Wrote $manifest for $((${#ASSET_FILES[@]} - 1)) asset(s)"
	fi
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
	# mid-upload, so the rerun has to converge on the complete asset set.
	UPLOAD_FILES=("${ASSET_FILES[@]}")
	if [[ "$IMMUTABLE_ASSETS" == "true" ]]; then
		# A published asset is immutable (release-security policy, section 4):
		# an asset that already landed with the same bytes is a no-op, one with
		# different bytes is a conflict that stops the rerun before any upload,
		# and one whose digest the API cannot report cannot be verified and is
		# treated the same way. Only assets that never landed are uploaded.
		# Tab-separated "name<TAB>digest" so an asset name with spaces still
		# matches its record; a lookup by whitespace field would miss it and
		# clobber it.
		if ! EXISTING_ASSETS=$(gh release view "$TAG" --repo "$REPO" --json assets \
			--jq '.assets[] | "\(.name)\t\(.digest // "")"'); then
			log_error "Could not list the assets of existing release $TAG"
			exit 1
		fi
		UPLOAD_FILES=()
		CONFLICTS=()
		for file in "${ASSET_FILES[@]}"; do
			name="$(basename "$file")"
			# "present <digest>" for a published asset, empty when it never landed.
			remote_entry="$(awk -F '\t' -v n="$name" '$1 == n { print "present " $2; exit }' <<<"$EXISTING_ASSETS")"
			if [[ -z "$remote_entry" ]]; then
				UPLOAD_FILES+=("$file")
				continue
			fi
			remote_digest="${remote_entry#present}"
			remote_digest="${remote_digest# }"
			local_digest="$(release_local_sha256 "$file")"
			if [[ "$remote_digest" == "sha256:${local_digest}" ]]; then
				log_info "Asset $name already published with the same digest; skipping"
			elif [[ -z "$remote_digest" ]]; then
				CONFLICTS+=("$name (published digest unknown; cannot verify)")
			else
				CONFLICTS+=("$name (published ${remote_digest}, local sha256:${local_digest})")
			fi
		done
		if ((${#CONFLICTS[@]} > 0)); then
			log_error "Refusing to overwrite published assets of release $TAG with different bytes:"
			for conflict in "${CONFLICTS[@]}"; do
				log_error "  - $conflict"
			done
			log_error "A published asset is immutable (release-security policy, section 4)."
			log_error "Resume with the original artifacts (recovery tier 2) or cut a new patch version (tier 3); never rebuild under the same version."
			exit 1
		fi
	fi
	if ((${#UPLOAD_FILES[@]} == 0)); then
		log_success "Every asset is already published on $RELEASE_URL; nothing to upload"
	else
		log_info "Uploading ${#UPLOAD_FILES[@]} asset(s) to existing release $TAG"
		# --clobber keeps a non-immutable rerun converging on an asset that
		# landed mid-attempt; with immutable assets the list holds only assets
		# that are not published, so it never overwrites.
		if ! gh release upload "$TAG" --repo "$REPO" --clobber "${UPLOAD_FILES[@]}"; then
			log_error "Failed to upload assets to existing release $TAG"
			exit 1
		fi
		log_success "Uploaded assets to existing release: $RELEASE_URL"
	fi
fi

# Get release info
RELEASE_ID=$(gh release view "$TAG" --repo "$REPO" --json id --jq '.id' 2>/dev/null || echo "")

# Output for GitHub Actions
set_github_output "release-url" "$RELEASE_URL"
set_github_output "release-id" "$RELEASE_ID"
set_github_output "tag" "$TAG"

echo "release-url=$RELEASE_URL"
echo "release-id=$RELEASE_ID"
