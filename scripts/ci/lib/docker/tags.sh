#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Docker image tag generation utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/tags.sh"
#   generate_semver_tags "v1.2.3"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_DOCKER_TAGS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_DOCKER_TAGS_LOADED=1

# Generate semantic version tags from a version string
# Usage: generate_semver_tags version [prefix]
# Args:
#   version - Semver version (e.g., v1.2.3 or 1.2.3)
#   prefix - Optional tag prefix (default: empty)
# Returns: newline-separated list of tags (e.g., 1, 1.2, 1.2.3)
generate_semver_tags() {
	local version="${1:-}"
	local prefix="${2:-}"

	# Strip leading 'v' if present
	version="${version#v}"

	# Validate semver format with optional prerelease and build metadata
	# Pattern: MAJOR.MINOR.PATCH[-prerelease][+build]
	if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
		echo "Error: Invalid semver format: $version" >&2
		return 1
	fi

	local major minor patch
	IFS='.' read -r major minor patch <<<"${version%%-*}"

	# Remove any suffix from patch (e.g., -rc.1)
	patch="${patch%%[^0-9]*}"

	# Output tags
	echo "${prefix}${major}"
	echo "${prefix}${major}.${minor}"
	echo "${prefix}${major}.${minor}.${patch}"

	# Add latest tag if this looks like a stable release
	if [[ ! "$version" =~ (alpha|beta|rc|dev|pre) ]]; then
		echo "${prefix}latest"
	fi
}

# Generate SHA-based tag
# Usage: generate_sha_tag [sha] [length]
# Args:
#   sha - Git commit SHA (default: from git rev-parse)
#   length - SHA length (default: 7)
generate_sha_tag() {
	local sha="${1:-}"
	local length="${2:-7}"

	if [[ -z "$sha" ]]; then
		sha="${GITHUB_SHA:-}"
	fi
	if [[ -z "$sha" ]]; then
		sha=$(git rev-parse HEAD 2>/dev/null || echo "")
	fi
	if [[ -z "$sha" ]]; then
		echo "Error: Could not determine git SHA" >&2
		return 1
	fi

	echo "sha-${sha:0:$length}"
}

# Generate branch-based tag
# Usage: generate_branch_tag [branch]
# Args:
#   branch - Branch name (default: from git/GITHUB_REF)
generate_branch_tag() {
	local branch="${1:-}"

	if [[ -z "$branch" ]]; then
		# Try GITHUB_REF_NAME first (cleaner)
		branch="${GITHUB_REF_NAME:-}"
	fi
	if [[ -z "$branch" ]]; then
		# Parse from GITHUB_REF
		if [[ -n "${GITHUB_REF:-}" ]]; then
			branch="${GITHUB_REF#refs/heads/}"
			branch="${branch#refs/tags/}"
		fi
	fi
	if [[ -z "$branch" ]]; then
		# Fallback to git
		branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
	fi
	if [[ -z "$branch" ]]; then
		echo "Error: Could not determine branch name" >&2
		return 1
	fi

	# Sanitize branch name for Docker tag
	# Replace / with - and remove invalid characters
	branch="${branch//\//-}"
	branch="${branch//[^a-zA-Z0-9._-]/}"

	echo "$branch"
}

# Generate PR-based tag
# Usage: generate_pr_tag [pr_number]
# Args:
#   pr_number - PR number (default: from GITHUB_EVENT)
generate_pr_tag() {
	local pr_number="${1:-}"

	if [[ -z "$pr_number" ]]; then
		# Try to extract from GITHUB_REF for PR events
		if [[ "${GITHUB_REF:-}" =~ refs/pull/([0-9]+)/ ]]; then
			pr_number="${BASH_REMATCH[1]}"
		fi
	fi

	if [[ -z "$pr_number" ]]; then
		return 1
	fi

	echo "pr-${pr_number}"
}

# Generate all standard tags for a build
# Usage: generate_docker_tags image_name [version]
# Args:
#   image_name - Full image name (e.g., ghcr.io/org/repo)
#   version - Optional version for semver tags
# Returns: newline-separated list of fully qualified tags
generate_docker_tags() {
	local image_name="${1:-}"
	local version="${2:-}"

	if [[ -z "$image_name" ]]; then
		echo "Error: Image name required" >&2
		return 1
	fi

	local tags=()

	# Add SHA tag (always)
	local sha_tag
	sha_tag=$(generate_sha_tag) && tags+=("${image_name}:${sha_tag}")

	# Add branch tag (for branch builds)
	local branch_tag
	branch_tag=$(generate_branch_tag 2>/dev/null) && tags+=("${image_name}:${branch_tag}")

	# Add PR tag (for PR builds)
	local pr_tag
	pr_tag=$(generate_pr_tag 2>/dev/null) && tags+=("${image_name}:${pr_tag}")

	# Add semver tags if version provided
	if [[ -n "$version" ]]; then
		while IFS= read -r tag; do
			tags+=("${image_name}:${tag}")
		done < <(generate_semver_tags "$version")
	fi

	# Output unique tags
	printf '%s\n' "${tags[@]}" | sort -u
}

# Export functions
export -f generate_semver_tags generate_sha_tag generate_branch_tag
export -f generate_pr_tag generate_docker_tags
