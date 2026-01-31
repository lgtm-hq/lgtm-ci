#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Version extraction utilities for package publishing
#
# Provides functions to extract versions from different package formats
# (pyproject.toml, package.json, gemspec) and detect prerelease versions.

# Guard against multiple sourcing
[[ -n "${_PUBLISH_VERSION_LOADED:-}" ]] && return 0
readonly _PUBLISH_VERSION_LOADED=1

# Extract version from pyproject.toml
# Usage: extract_pypi_version [path]
# Returns version string or empty if not found
extract_pypi_version() {
	local path="${1:-.}"
	local pyproject="$path/pyproject.toml"

	if [[ ! -f "$pyproject" ]]; then
		return 1
	fi

	# Try [project] table first (PEP 621) - only match version within [project] section
	local version
	version=$(awk '/^\[project\]$/,/^\[/ { if (/^version[[:space:]]*=/) print }' "$pyproject" |
		head -1 | sed 's/.*=[[:space:]]*["\x27]\([^"\x27]*\)["\x27].*/\1/')

	if [[ -z "$version" ]]; then
		# Try [tool.poetry] for Poetry projects
		version=$(awk '/^\[tool\.poetry\]$/,/^\[/ { if (/^version[[:space:]]*=/) print }' "$pyproject" |
			head -1 | sed 's/.*=[[:space:]]*["\x27]\([^"\x27]*\)["\x27].*/\1/')
	fi

	if [[ -n "$version" ]]; then
		echo "$version"
		return 0
	fi

	return 1
}

# Extract version from package.json
# Usage: extract_npm_version [path]
# Returns version string or empty if not found
extract_npm_version() {
	local path="${1:-.}"
	local package_json="$path/package.json"

	if [[ ! -f "$package_json" ]]; then
		return 1
	fi

	# Use grep/sed to avoid jq dependency (POSIX character classes for portability)
	local version
	version=$(grep -E '^[[:space:]]*"version"[[:space:]]*:' "$package_json" | head -1 |
		sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')

	if [[ -n "$version" ]]; then
		echo "$version"
		return 0
	fi

	return 1
}

# Extract version from gemspec file
# Usage: extract_gem_version [gemspec_path]
# If gemspec_path is a directory, auto-detects *.gemspec
# Returns version string or empty if not found
extract_gem_version() {
	local path="${1:-.}"
	local gemspec="$path"

	# Auto-detect gemspec if directory provided
	if [[ -d "$path" ]]; then
		gemspec=$(find "$path" -maxdepth 1 -name "*.gemspec" -print -quit 2>/dev/null)
		if [[ -z "$gemspec" ]]; then
			return 1
		fi
	fi

	if [[ ! -f "$gemspec" ]]; then
		return 1
	fi

	local version=""

	# Try Ruby evaluation first (handles constant-based versions)
	if command -v ruby >/dev/null 2>&1; then
		version=$(ruby -e "
			begin
				spec = Gem::Specification.load('$gemspec')
				puts spec.version if spec
			rescue => e
				# Silently fail - will use fallback
			end
		" 2>/dev/null)
	fi

	# Fallback to grep/sed pattern for quoted literals
	if [[ -z "$version" ]]; then
		version=$(grep -E '\.(version)[[:space:]]*=' "$gemspec" | head -1 |
			sed 's/.*=[[:space:]]*["\x27]\([^"\x27]*\)["\x27].*/\1/')
	fi

	if [[ -n "$version" ]]; then
		echo "$version"
		return 0
	fi

	return 1
}

# Detect if version is a prerelease
# Usage: is_prerelease_version "1.2.3-alpha.1"
# Returns 0 (true) if prerelease, 1 (false) if stable
is_prerelease_version() {
	local version="${1:-}"
	version="${version#v}" # Strip optional v prefix

	# SemVer prerelease: contains hyphen followed by prerelease identifier
	# Also detect common patterns: alpha, beta, rc, dev, pre
	if [[ "$version" =~ -[a-zA-Z0-9] ]]; then
		return 0
	fi

	# npm prerelease patterns (e.g., 1.0.0-0, 1.0.0-alpha)
	# Python prerelease patterns (e.g., 1.0.0a1, 1.0.0b2, 1.0.0rc1, 1.0.0.dev1)
	if [[ "$version" =~ [0-9](a|b|rc|alpha|beta|dev|pre)[0-9]* ]]; then
		return 0
	fi

	return 1
}

# Get npm dist-tag based on version
# Usage: get_dist_tag_for_version "1.2.3-beta.1"
# Returns: latest, beta, alpha, next, or rc
get_dist_tag_for_version() {
	local version="${1:-}"
	version="${version#v}"

	# Check for specific prerelease patterns
	if [[ "$version" =~ -(alpha|a)[.0-9]* ]] || [[ "$version" =~ [0-9]a[0-9] ]]; then
		echo "alpha"
		return 0
	fi

	if [[ "$version" =~ -(beta|b)[.0-9]* ]] || [[ "$version" =~ [0-9]b[0-9] ]]; then
		echo "beta"
		return 0
	fi

	if [[ "$version" =~ -(rc|pre)[.0-9]* ]] || [[ "$version" =~ [0-9]rc[0-9] ]]; then
		echo "rc"
		return 0
	fi

	if [[ "$version" =~ -(next|dev)[.0-9]* ]] || [[ "$version" =~ [0-9]dev[0-9] ]]; then
		echo "next"
		return 0
	fi

	# Default to latest for stable versions
	echo "latest"
}

# =============================================================================
# Export functions
# =============================================================================
export -f extract_pypi_version extract_npm_version extract_gem_version
export -f is_prerelease_version get_dist_tag_for_version
