#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Version extraction utilities for release automation
#
# Extract version numbers from various project files.
# Returns non-zero if version cannot be found.

set -euo pipefail

# Guard against multiple sourcing
[[ -n "${_RELEASE_EXTRACT_LOADED:-}" ]] && return 0
readonly _RELEASE_EXTRACT_LOADED=1

# Extract version from pyproject.toml
# Usage: extract_version_pyproject "pyproject.toml"
# Returns: 0 with version on stdout, 1 if not found
extract_version_pyproject() {
	local file="${1:-pyproject.toml}"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	local version
	version=$(grep -E '^version\s*=' "$file" | head -1 | sed -E 's/.*=\s*["\x27]([^"\x27]+)["\x27].*/\1/' || true)

	if [[ -z "$version" ]]; then
		return 1
	fi

	echo "$version"
}

# Extract version from package.json
# Usage: extract_version_package_json "package.json"
# Returns: 0 with version on stdout, 1 if not found
extract_version_package_json() {
	local file="${1:-package.json}"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	local version
	if command -v jq &>/dev/null; then
		version=$(jq -r '.version // empty' "$file" 2>/dev/null || true)
	else
		version=$(grep -E '"version"\s*:' "$file" | head -1 | sed -E 's/.*:\s*"([^"]+)".*/\1/' || true)
	fi

	if [[ -z "$version" ]]; then
		return 1
	fi

	echo "$version"
}

# Extract version from Cargo.toml
# Usage: extract_version_cargo "Cargo.toml"
# Returns: 0 with version on stdout, 1 if not found
extract_version_cargo() {
	local file="${1:-Cargo.toml}"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	local version
	version=$(grep -E '^version\s*=' "$file" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)

	if [[ -z "$version" ]]; then
		return 1
	fi

	echo "$version"
}

# Extract version from git tag (latest)
# Usage: extract_version_git_tag "v*"
# Returns: 0 with version on stdout, 1 if not found
extract_version_git_tag() {
	local pattern="${1:-v*}"

	local tag
	if ! tag=$(git describe --tags --abbrev=0 --match "$pattern" 2>/dev/null); then
		return 1
	fi

	if [[ -z "$tag" ]]; then
		return 1
	fi

	# Strip v prefix and output
	echo "${tag#v}"
}
