#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Delete per-platform staging manifests from GHCR after a multi-arch merge
#          (build-docker STEP: cleanup-staging)
#
# Uses the GitHub Packages API; skips non-GHCR registries.
#
# Required environment variables:
#   IMAGE_NAME - Registry-relative image name (e.g. org/repo or org/group/repo)
#   RUN_ID     - GitHub Actions run ID used to construct staging tag names
#   GH_TOKEN   - GitHub token with packages:delete permission
#   MATRIX     - JSON matrix from classify step (array of {platform, runner, slug, qemu})

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${RUN_ID:?RUN_ID is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${MATRIX:?MATRIX is required}"

# Parse owner and package name; URL-encode nested slashes
pkg_owner="${IMAGE_NAME%%/*}"
pkg_name="${IMAGE_NAME#*/}"
pkg_name_encoded="${pkg_name//\//%2F}"

while IFS= read -r slug; do
	[[ -z "$slug" ]] && continue
	tag="build-${RUN_ID}-${slug}"
	log_info "Looking up staging manifest: ${tag}"

	# Prefer org endpoint; fall back to user endpoint for personal repos
	version_id=$(
		gh api "orgs/${pkg_owner}/packages/container/${pkg_name_encoded}/versions" \
			--paginate \
			--jq ".[] | select(.metadata.container.tags[]? == \"${tag}\") | .id" \
			2>/dev/null ||
			gh api "user/packages/container/${pkg_name_encoded}/versions" \
				--paginate \
				--jq ".[] | select(.metadata.container.tags[]? == \"${tag}\") | .id" \
				2>/dev/null ||
			true
	)

	if [[ -n "${version_id}" ]]; then
		deleted=false
		if gh api --method DELETE \
			"orgs/${pkg_owner}/packages/container/${pkg_name_encoded}/versions/${version_id}" \
			2>/dev/null; then
			deleted=true
		elif gh api --method DELETE \
			"user/packages/container/${pkg_name_encoded}/versions/${version_id}" \
			2>/dev/null; then
			deleted=true
		fi
		if [[ "$deleted" == true ]]; then
			log_success "Deleted staging manifest: ${tag}"
		else
			log_warn "Failed to delete staging manifest: ${tag} (version ${version_id})"
		fi
	else
		log_warn "Could not locate staging manifest version for tag ${tag} — skipping deletion"
	fi
done < <(echo "$MATRIX" | jq -r '.[].slug')
