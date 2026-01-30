#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Version extraction utilities for release automation
#
# Extract version numbers from various project files.

# Guard against multiple sourcing
[[ -n "${_RELEASE_EXTRACT_LOADED:-}" ]] && return 0
readonly _RELEASE_EXTRACT_LOADED=1

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
