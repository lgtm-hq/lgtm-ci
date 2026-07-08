#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ephemeral GHCR build-cache tag detection for prune eligibility
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/tags.sh"
#   ghcr_is_ephemeral_only_tagged '["pr-42"]'

[[ -n "${_LGTM_CI_GHCR_TAGS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GHCR_TAGS_LOADED=1

readonly _GHCR_EPHEMERAL_TAG_PATTERN='^(pr-[a-zA-Z0-9_.-]+|mq-[a-zA-Z0-9_.-]+|dispatch-[a-zA-Z0-9_.-]+)$'

# Per-platform staging tags produced by the multi-arch publish
# (merge-manifests.sh: build-${RUN_ID}-${slug}). RUN_ID is a numeric GitHub
# Actions run id; slug is a platform slug such as linux-amd64 or linux-arm-v7.
readonly _GHCR_BUILD_STAGING_TAG_PATTERN='^build-[0-9]+-[a-zA-Z0-9._-]+$'

# Return 0 when every tag on the version matches the ephemeral pattern.
# Args:
#   $1 - JSON array of tag strings
ghcr_is_ephemeral_only_tagged() {
	local tags_json="${1:-[]}"
	local tag_count ephemeral_count

	tag_count=$(jq -r 'length' <<<"$tags_json")
	[[ "$tag_count" -eq 0 ]] && return 1

	ephemeral_count=$(
		jq -r --arg pattern "$_GHCR_EPHEMERAL_TAG_PATTERN" '
			[.[] | select(test($pattern))] | length
		' <<<"$tags_json"
	)

	[[ "$ephemeral_count" -eq "$tag_count" ]]
}

# Return 0 when every tag on the version is a build-<run_id>-<slug> staging tag.
# Versions carrying any release/permanent tag (latest, vX.Y.Z, ...) are rejected
# so the pruner never mistakes a live release index for a staging manifest.
# Args:
#   $1 - JSON array of tag strings
ghcr_is_build_staging_only_tagged() {
	local tags_json="${1:-[]}"
	local tag_count staging_count

	tag_count=$(jq -r 'length' <<<"$tags_json")
	[[ "$tag_count" -eq 0 ]] && return 1

	staging_count=$(
		jq -r --arg pattern "$_GHCR_BUILD_STAGING_TAG_PATTERN" '
			[.[] | select(test($pattern))] | length
		' <<<"$tags_json"
	)

	[[ "$staging_count" -eq "$tag_count" ]]
}

export -f ghcr_is_ephemeral_only_tagged ghcr_is_build_staging_only_tagged
