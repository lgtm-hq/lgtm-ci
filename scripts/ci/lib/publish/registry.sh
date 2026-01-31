#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Registry availability utilities for package publishing
#
# Provides functions to check package availability on registries
# and wait for packages with exponential backoff.

# Guard against multiple sourcing
[[ -n "${_PUBLISH_REGISTRY_LOADED:-}" ]] && return 0
readonly _PUBLISH_REGISTRY_LOADED=1

# PyPI registry URLs
readonly PYPI_API_URL="https://pypi.org/pypi"
readonly TEST_PYPI_API_URL="https://test.pypi.org/pypi"

# npm registry URL
readonly NPM_REGISTRY_URL="https://registry.npmjs.org"

# RubyGems API URL
readonly RUBYGEMS_API_URL="https://rubygems.org/api/v1/gems"

# Check if a package version exists on PyPI
# Usage: check_pypi_availability "package-name" "1.2.3" [test-pypi]
# Returns 0 if available, 1 otherwise
check_pypi_availability() {
	local package="${1:?Package name required}"
	local version="${2:?Version required}"
	local test_pypi="${3:-false}"

	local api_url="$PYPI_API_URL"
	if [[ "$test_pypi" == "true" ]]; then
		api_url="$TEST_PYPI_API_URL"
	fi

	local url="$api_url/$package/$version/json"
	local response
	response=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)

	if [[ "$response" == "200" ]]; then
		return 0
	fi

	return 1
}

# Check if a package version exists on npm
# Usage: check_npm_availability "package-name" "1.2.3"
# Returns 0 if available, 1 otherwise
check_npm_availability() {
	local package="${1:?Package name required}"
	local version="${2:?Version required}"

	local url="$NPM_REGISTRY_URL/$package/$version"
	local response
	response=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)

	if [[ "$response" == "200" ]]; then
		return 0
	fi

	return 1
}

# Check if a gem version exists on RubyGems
# Usage: check_rubygems_availability "gem-name" "1.2.3"
# Returns 0 if available, 1 otherwise
check_rubygems_availability() {
	local gem_name="${1:?Gem name required}"
	local version="${2:?Version required}"

	# RubyGems API returns gem info, check versions array
	local url="$RUBYGEMS_API_URL/$gem_name.json"
	local response
	response=$(curl -s "$url" 2>/dev/null)

	if [[ -z "$response" ]] || [[ "$response" == "This rubygem could not be found." ]]; then
		return 1
	fi

	# Check if version exists in response (exact match with word boundaries)
	# The version field in RubyGems JSON is the exact version string
	if echo "$response" | grep -qE "\"version\":\"${version}\"(,|})"; then
		return 0
	fi

	return 1
}

# Wait for a package to be available on a registry
# Usage: wait_for_package "pypi|npm|gem" "package-name" "1.2.3" [max_wait_seconds] [test-pypi]
# Returns 0 when available, 1 on timeout
wait_for_package() {
	local registry="${1:?Registry type required (pypi|npm|gem)}"
	local package="${2:?Package name required}"
	local version="${3:?Version required}"
	local max_wait="${4:-600}" # Default 10 minutes
	local extra_arg="${5:-}"   # For test-pypi flag

	local start_time
	start_time=$(date +%s)
	local attempt=1
	local delay=5 # Start with 5 second delay

	log_info "Waiting for $package@$version on $registry..."

	while true; do
		local elapsed
		elapsed=$(($(date +%s) - start_time))

		if ((elapsed >= max_wait)); then
			log_error "Timeout waiting for $package@$version after ${max_wait}s"
			return 1
		fi

		local available=false
		case "$registry" in
		pypi)
			if check_pypi_availability "$package" "$version" "$extra_arg"; then
				available=true
			fi
			;;
		npm)
			if check_npm_availability "$package" "$version"; then
				available=true
			fi
			;;
		gem | rubygems)
			if check_rubygems_availability "$package" "$version"; then
				available=true
			fi
			;;
		*)
			log_error "Unknown registry: $registry"
			return 1
			;;
		esac

		if [[ "$available" == "true" ]]; then
			log_success "$package@$version is now available on $registry"
			return 0
		fi

		log_verbose "Attempt $attempt: Not yet available, waiting ${delay}s..."
		sleep "$delay"

		# Exponential backoff with cap at 60 seconds
		delay=$((delay * 2))
		if ((delay > 60)); then
			delay=60
		fi
		((attempt++))
	done
}

# Get PyPI download URL for a specific version
# Usage: get_pypi_download_url "package-name" "1.2.3" [test-pypi]
# Returns the sdist (.tar.gz) download URL
get_pypi_download_url() {
	local package="${1:?Package name required}"
	local version="${2:?Version required}"
	local test_pypi="${3:-false}"

	local api_url="$PYPI_API_URL"
	if [[ "$test_pypi" == "true" ]]; then
		api_url="$TEST_PYPI_API_URL"
	fi

	local url="$api_url/$package/$version/json"
	local response
	response=$(curl -s "$url" 2>/dev/null)

	if [[ -z "$response" ]]; then
		return 1
	fi

	# Extract sdist URL (prefer .tar.gz)
	local download_url
	download_url=$(echo "$response" | grep -o '"url":"[^"]*\.tar\.gz"' | head -1 | sed 's/"url":"\([^"]*\)"/\1/')

	if [[ -n "$download_url" ]]; then
		echo "$download_url"
		return 0
	fi

	return 1
}

# Get SHA256 hash for a PyPI package version
# Usage: get_pypi_sha256 "package-name" "1.2.3" [test-pypi]
# Returns the SHA256 hash of the sdist
get_pypi_sha256() {
	local package="${1:?Package name required}"
	local version="${2:?Version required}"
	local test_pypi="${3:-false}"

	local api_url="$PYPI_API_URL"
	if [[ "$test_pypi" == "true" ]]; then
		api_url="$TEST_PYPI_API_URL"
	fi

	local url="$api_url/$package/$version/json"
	local response
	response=$(curl -s "$url" 2>/dev/null)

	if [[ -z "$response" ]]; then
		return 1
	fi

	# Find the sdist entry and extract sha256
	# Look for entries with packagetype "sdist" and extract digests.sha256
	local sha256
	# Find sdist block and extract sha256 - this is a simplified approach
	sha256=$(echo "$response" | grep -A 10 '"packagetype":"sdist"' | grep -o '"sha256":"[^"]*"' | head -1 | sed 's/"sha256":"\([^"]*\)"/\1/')

	if [[ -n "$sha256" ]]; then
		echo "$sha256"
		return 0
	fi

	return 1
}

# =============================================================================
# Export functions
# =============================================================================
export -f check_pypi_availability check_npm_availability check_rubygems_availability
export -f wait_for_package get_pypi_download_url get_pypi_sha256
