#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Semantic versioning utilities for release automation
#
# Provides functions for parsing, validating, and bumping semantic versions.

# Guard against multiple sourcing
[[ -n "${_RELEASE_VERSION_LOADED:-}" ]] && return 0
readonly _RELEASE_VERSION_LOADED=1

# Validate semver format (X.Y.Z with optional v prefix)
# Usage: validate_semver "1.2.3" || die "Invalid version"
validate_semver() {
	local version="${1:-}"
	# Strip optional v prefix
	version="${version#v}"
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$ ]]
}

# Parse version into components
# Usage: parse_version "1.2.3" -> sets MAJOR, MINOR, PATCH globals
parse_version() {
	local version="${1:-}"
	# Strip optional v prefix
	version="${version#v}"

	if ! validate_semver "$version"; then
		return 1
	fi

	# Extract core version (strip prerelease and build metadata)
	local core="${version%%-*}"
	core="${core%%+*}"

	MAJOR="${core%%.*}"
	local rest="${core#*.}"
	MINOR="${rest%%.*}"
	PATCH="${rest#*.}"

	export MAJOR MINOR PATCH
}

# Bump version based on bump type
# Usage: bump_version "1.2.3" "minor" -> "1.3.0"
bump_version() {
	local version="${1:-}"
	local bump_type="${2:-patch}"

	if ! parse_version "$version"; then
		echo "Invalid version: $version" >&2
		return 1
	fi

	case "$bump_type" in
	major)
		MAJOR=$((MAJOR + 1))
		MINOR=0
		PATCH=0
		;;
	minor)
		MINOR=$((MINOR + 1))
		PATCH=0
		;;
	patch)
		PATCH=$((PATCH + 1))
		;;
	*)
		echo "Invalid bump type: $bump_type (expected: major, minor, patch)" >&2
		return 1
		;;
	esac

	echo "${MAJOR}.${MINOR}.${PATCH}"
}

# Compare two versions
# Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
# Usage: compare_versions "1.2.3" "1.2.4" -> returns 2
compare_versions() {
	local v1="${1:-}"
	local v2="${2:-}"

	# Strip v prefix
	v1="${v1#v}"
	v2="${v2#v}"

	if [[ "$v1" == "$v2" ]]; then
		return 0
	fi

	local IFS='.'
	read -ra v1_parts <<<"$v1"
	read -ra v2_parts <<<"$v2"

	for i in 0 1 2; do
		local p1="${v1_parts[$i]:-0}"
		local p2="${v2_parts[$i]:-0}"

		# Strip any prerelease/build metadata from patch
		p1="${p1%%-*}"
		p1="${p1%%+*}"
		p2="${p2%%-*}"
		p2="${p2%%+*}"

		if ((p1 > p2)); then
			return 1
		elif ((p1 < p2)); then
			return 2
		fi
	done

	return 0
}

# Get the higher of two bump types
# Usage: max_bump "patch" "minor" -> "minor"
max_bump() {
	local b1="${1:-patch}"
	local b2="${2:-patch}"

	case "$b1" in
	major) echo "major" ;;
	minor)
		if [[ "$b2" == "major" ]]; then
			echo "major"
		else
			echo "minor"
		fi
		;;
	patch)
		echo "$b2"
		;;
	*)
		echo "$b2"
		;;
	esac
}

# Clamp bump type to maximum allowed
# Usage: clamp_bump "major" "minor" -> "minor"
clamp_bump() {
	local bump="${1:-patch}"
	local max="${2:-major}"

	case "$max" in
	patch)
		echo "patch"
		;;
	minor)
		if [[ "$bump" == "major" ]]; then
			echo "minor"
		else
			echo "$bump"
		fi
		;;
	major)
		echo "$bump"
		;;
	*)
		echo "$bump"
		;;
	esac
}

# Extract version from pyproject.toml
# Usage: extract_version_pyproject "pyproject.toml"
extract_version_pyproject() {
	local file="${1:-pyproject.toml}"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	grep -E '^version\s*=' "$file" | head -1 | sed -E 's/.*=\s*["\x27]([^"\x27]+)["\x27].*/\1/'
}

# Extract version from package.json
# Usage: extract_version_package_json "package.json"
extract_version_package_json() {
	local file="${1:-package.json}"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	if command -v jq &>/dev/null; then
		jq -r '.version // empty' "$file"
	else
		grep -E '"version"\s*:' "$file" | head -1 | sed -E 's/.*:\s*"([^"]+)".*/\1/'
	fi
}

# Extract version from Cargo.toml
# Usage: extract_version_cargo "Cargo.toml"
extract_version_cargo() {
	local file="${1:-Cargo.toml}"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	grep -E '^version\s*=' "$file" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/'
}

# Extract version from git tag (latest)
# Usage: extract_version_git_tag "v*"
extract_version_git_tag() {
	local pattern="${1:-v*}"

	git describe --tags --abbrev=0 --match "$pattern" 2>/dev/null | sed 's/^v//'
}
