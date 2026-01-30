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

# Compare two prerelease identifiers according to SemVer
# Returns: 0 if equal, 1 if id1 > id2, 2 if id1 < id2
_compare_prerelease_id() {
	local id1="${1:-}"
	local id2="${2:-}"

	# Both numeric - compare numerically (force base-10 to avoid octal parsing)
	if [[ "$id1" =~ ^[0-9]+$ ]] && [[ "$id2" =~ ^[0-9]+$ ]]; then
		if ((10#$id1 > 10#$id2)); then
			return 1
		elif ((10#$id1 < 10#$id2)); then
			return 2
		fi
		return 0
	fi

	# Numeric has lower precedence than non-numeric
	if [[ "$id1" =~ ^[0-9]+$ ]]; then
		return 2
	fi
	if [[ "$id2" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	# Both non-numeric - compare lexically
	if [[ "$id1" > "$id2" ]]; then
		return 1
	elif [[ "$id1" < "$id2" ]]; then
		return 2
	fi
	return 0
}

# Compare two prerelease strings according to SemVer
# Empty prerelease (release version) > any prerelease
# Returns: 0 if equal, 1 if pre1 > pre2, 2 if pre1 < pre2
_compare_prerelease() {
	local pre1="${1:-}"
	local pre2="${2:-}"

	# Both empty - equal
	if [[ -z "$pre1" ]] && [[ -z "$pre2" ]]; then
		return 0
	fi

	# Empty prerelease (release) > any prerelease
	if [[ -z "$pre1" ]]; then
		return 1
	fi
	if [[ -z "$pre2" ]]; then
		return 2
	fi

	# Split by dots and compare identifiers
	local IFS='.'
	read -ra ids1 <<<"$pre1"
	read -ra ids2 <<<"$pre2"

	local len1=${#ids1[@]}
	local len2=${#ids2[@]}
	local max_len=$((len1 > len2 ? len1 : len2))

	for ((i = 0; i < max_len; i++)); do
		local id1="${ids1[$i]:-}"
		local id2="${ids2[$i]:-}"

		# Fewer identifiers = lower precedence
		if [[ -z "$id1" ]]; then
			return 2
		fi
		if [[ -z "$id2" ]]; then
			return 1
		fi

		_compare_prerelease_id "$id1" "$id2"
		local result=$?
		if ((result != 0)); then
			return $result
		fi
	done

	return 0
}

# Compare two versions (SemVer-aware including prerelease)
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

	# Strip build metadata (ignored in comparison per SemVer)
	v1="${v1%%+*}"
	v2="${v2%%+*}"

	# Extract prerelease parts
	local pre1="" pre2=""
	if [[ "$v1" == *-* ]]; then
		pre1="${v1#*-}"
		v1="${v1%%-*}"
	fi
	if [[ "$v2" == *-* ]]; then
		pre2="${v2#*-}"
		v2="${v2%%-*}"
	fi

	# Compare major.minor.patch
	local IFS='.'
	read -ra v1_parts <<<"$v1"
	read -ra v2_parts <<<"$v2"

	for i in 0 1 2; do
		local p1="${v1_parts[$i]:-0}"
		local p2="${v2_parts[$i]:-0}"

		if ((p1 > p2)); then
			return 1
		elif ((p1 < p2)); then
			return 2
		fi
	done

	# Major.minor.patch are equal - compare prerelease
	_compare_prerelease "$pre1" "$pre2"
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
