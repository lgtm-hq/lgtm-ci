#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Tagged-image retention classification for GHCR pruning
#
# Ported from lgtm-hq/Rustume's inline `prune-tagged` job
# (.github/workflows/ghcr-cleanup.yml + scripts/ci/maintenance/ghcr-prune-tags.sh),
# which proved the policy in production before it was generalised here (#759).
#
# Retention classes:
#   permanent  - latest, semver (x, x.y, x.y.z, optional leading v): never deleted
#   main       - main, sha-*: deleted past the main cutoff
#   prerelease - alpha/beta/rc/pre/dev/snapshot shapes: deleted past the
#                prerelease cutoff
#   unknown    - anything else: never deleted (fail safe)
#
# THE RULE THAT MUST NOT BE INVERTED
#   A GHCR version can carry several tags on one manifest. Delete a version
#   only when EVERY tag on it is deletable -- never when any single tag is.
#   A release build publishes :latest + :<semver> + :sha-<commit> onto one
#   manifest. Under all-must-agree that version is retained forever because
#   latest and semver say keep, so the release's immutable sha- pin survives.
#   Invert this to "delete if any tag is deletable" and every release image is
#   deleted the moment its sha- tag ages out while :latest still points at it,
#   which corrupts the registry. See ghcr_all_tags_deletable.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/retention.sh"
#   ghcr_tag_retention_class "1.2.3"
#   ghcr_all_tags_deletable '["latest","1.2.3","sha-abc123"]' \
#       "2024-01-01T00:00:00Z" "$main_cutoff" "$prerelease_cutoff"

[[ -n "${_LGTM_CI_GHCR_RETENTION_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GHCR_RETENTION_LOADED=1

# Semver-ish release tags: 1, 1.2, 1.2.3, with an optional leading v.
readonly _GHCR_SEMVER_TAG_PATTERN='^v?[0-9]+(\.[0-9]+)?(\.[0-9]+)?$'

# Mutable branch tag and the immutable per-commit tag produced by the default
# reusable-docker tag matrix.
readonly _GHCR_MAIN_TAG_PATTERN='^(main|sha-.+)$'

# Pre-release channels. Deliberately anchored and tighter than the upstream
# Rustume regex, which was unanchored and classified tags such as `predeploy`
# as pre-release. Tightening can only move a tag into the never-delete
# `unknown` class, which is the fail-safe direction.
readonly _GHCR_PRERELEASE_TAG_PATTERN='^(.*-)?(alpha|beta|rc|pre|dev|snapshot)([0-9._-].*)?$'

# Classify a single tag into a retention class.
# Args:
#   $1 - tag
# Prints one of: permanent, main, prerelease, unknown
ghcr_tag_retention_class() {
	local tag="${1-}"

	if [[ "$tag" == "latest" ]]; then
		printf 'permanent\n'
		return 0
	fi
	if [[ "$tag" =~ $_GHCR_SEMVER_TAG_PATTERN ]]; then
		printf 'permanent\n'
		return 0
	fi
	if [[ "$tag" =~ $_GHCR_MAIN_TAG_PATTERN ]]; then
		printf 'main\n'
		return 0
	fi
	if [[ "$tag" =~ $_GHCR_PRERELEASE_TAG_PATTERN ]]; then
		printf 'prerelease\n'
		return 0
	fi
	printf 'unknown\n'
}

# Return 0 when a single tag is deletable at the given version timestamp.
# Args:
#   $1 - tag
#   $2 - version timestamp (RFC 3339, UTC, e.g. 2024-01-01T00:00:00Z)
#   $3 - main cutoff timestamp (same format)
#   $4 - prerelease cutoff timestamp (same format)
ghcr_tag_is_deletable() {
	local tag="${1-}"
	local version_time="${2-}"
	local main_cutoff="${3:?main cutoff required}"
	local prerelease_cutoff="${4:?prerelease cutoff required}"
	local class

	# No usable timestamp means no defensible age -- keep.
	[[ -z "$version_time" ]] && return 1

	class=$(ghcr_tag_retention_class "$tag")

	case "$class" in
	main) [[ "$version_time" < "$main_cutoff" ]] ;;
	prerelease) [[ "$version_time" < "$prerelease_cutoff" ]] ;;
	*) return 1 ;;
	esac
}

# Return 0 only when EVERY tag on the version is deletable.
#
# Read the header comment before touching this function. Any single
# non-deletable tag (latest, semver, an unrecognised shape, or an in-retention
# main/sha- tag) retains the whole version, because all of those tags share one
# manifest and deleting the version would break every one of them.
#
# Args:
#   $1 - JSON array of tag strings
#   $2 - version timestamp (RFC 3339, UTC)
#   $3 - main cutoff timestamp
#   $4 - prerelease cutoff timestamp
ghcr_all_tags_deletable() {
	local tags_json="${1:-[]}"
	local version_time="${2-}"
	local main_cutoff="${3:?main cutoff required}"
	local prerelease_cutoff="${4:?prerelease cutoff required}"
	local -a tags=()
	local tag

	# Untagged versions are the untagged pruner's business, not ours.
	if ! jq -e 'type == "array" and length > 0' <<<"$tags_json" >/dev/null 2>&1; then
		return 1
	fi

	mapfile -t tags < <(jq -r '.[]' <<<"$tags_json")

	for tag in "${tags[@]}"; do
		if ! ghcr_tag_is_deletable \
			"$tag" \
			"$version_time" \
			"$main_cutoff" \
			"$prerelease_cutoff"; then
			return 1
		fi
	done

	return 0
}

# The patterns travel with the exported functions: a child bash process that
# inherits the functions without them would evaluate an empty regex.
export _GHCR_SEMVER_TAG_PATTERN _GHCR_MAIN_TAG_PATTERN _GHCR_PRERELEASE_TAG_PATTERN
export -f ghcr_tag_retention_class ghcr_tag_is_deletable ghcr_all_tags_deletable
