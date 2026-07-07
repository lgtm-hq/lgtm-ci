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

export -f ghcr_is_ephemeral_only_tagged
