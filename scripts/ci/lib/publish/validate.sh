#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Package validation utilities for publishing
#
# Provides functions to validate packages before publishing to registries.

# Guard against multiple sourcing
[[ -n "${_PUBLISH_VALIDATE_LOADED:-}" ]] && return 0
readonly _PUBLISH_VALIDATE_LOADED=1

# Validate PyPI package distribution files
# Usage: validate_pypi_package dist/
# Returns 0 if valid, 1 otherwise
validate_pypi_package() {
	local dist_dir="${1:-dist}"

	if [[ ! -d "$dist_dir" ]]; then
		log_error "Distribution directory not found: $dist_dir"
		return 1
	fi

	# Check for wheel or sdist files
	local has_files=false
	if compgen -G "$dist_dir/*.whl" >/dev/null || compgen -G "$dist_dir/*.tar.gz" >/dev/null; then
		has_files=true
	fi

	if [[ "$has_files" != "true" ]]; then
		log_error "No distribution files found in $dist_dir"
		return 1
	fi

	# Run twine check if available
	if command -v twine >/dev/null 2>&1; then
		log_info "Running twine check..."
		if ! twine check "$dist_dir"/*; then
			log_error "twine check failed"
			return 1
		fi
		log_success "twine check passed"
	elif command -v uv >/dev/null 2>&1; then
		log_info "Running twine check via uv..."
		if ! uv run twine check "$dist_dir"/*; then
			log_error "twine check failed"
			return 1
		fi
		log_success "twine check passed"
	else
		log_warn "twine not available, skipping package validation"
	fi

	return 0
}

# Validate npm package.json has required fields
# Usage: validate_npm_package [path]
# Returns 0 if valid, 1 otherwise
validate_npm_package() {
	local path="${1:-.}"
	local package_json="$path/package.json"

	if [[ ! -f "$package_json" ]]; then
		log_error "package.json not found at $path"
		return 1
	fi

	local errors=0

	# Check required fields
	local name version
	name=$(grep -E '^\s*"name"\s*:' "$package_json" | sed 's/.*:\s*"\([^"]*\)".*/\1/')
	version=$(grep -E '^\s*"version"\s*:' "$package_json" | sed 's/.*:\s*"\([^"]*\)".*/\1/')

	if [[ -z "$name" ]]; then
		log_error "Missing required field: name"
		((errors++))
	fi

	if [[ -z "$version" ]]; then
		log_error "Missing required field: version"
		((errors++))
	fi

	# Validate package name format
	if [[ -n "$name" ]]; then
		# npm package names must be lowercase, may contain hyphens/underscores/dots
		if [[ ! "$name" =~ ^(@[a-z0-9._-]+/)?[a-z0-9._-]+$ ]]; then
			log_error "Invalid package name format: $name"
			((errors++))
		fi
	fi

	# Validate version format (semver)
	if [[ -n "$version" ]]; then
		if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
			log_error "Invalid version format: $version (expected semver)"
			((errors++))
		fi
	fi

	if ((errors > 0)); then
		return 1
	fi

	log_success "package.json validation passed"
	return 0
}

# Validate gem package
# Usage: validate_gem_package [gemspec_path]
# Returns 0 if valid, 1 otherwise
validate_gem_package() {
	local path="${1:-.}"
	local gemspec="$path"

	# Auto-detect gemspec if directory provided
	if [[ -d "$path" ]]; then
		gemspec=$(find "$path" -maxdepth 1 -name "*.gemspec" -print -quit 2>/dev/null)
		if [[ -z "$gemspec" ]]; then
			log_error "No gemspec found in $path"
			return 1
		fi
	fi

	if [[ ! -f "$gemspec" ]]; then
		log_error "Gemspec not found: $gemspec"
		return 1
	fi

	# Check required fields exist
	local errors=0
	local name version

	name=$(grep -E '\.(name)\s*=' "$gemspec" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/')
	version=$(grep -E '\.(version)\s*=' "$gemspec" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/')

	if [[ -z "$name" ]]; then
		log_error "Missing required field: name"
		((errors++))
	fi

	if [[ -z "$version" ]]; then
		log_error "Missing required field: version"
		((errors++))
	fi

	# Run gem build --strict to validate
	if command -v gem >/dev/null 2>&1; then
		log_info "Validating gemspec syntax..."
		if ! gem build "$gemspec" --strict 2>/dev/null; then
			log_warn "gem build validation produced warnings"
		fi
		# Clean up built gem if created
		rm -f ./*.gem 2>/dev/null
	fi

	if ((errors > 0)); then
		return 1
	fi

	log_success "Gemspec validation passed"
	return 0
}

# Validate version string format (semver)
# Usage: validate_version_format "1.2.3"
# Returns 0 if valid semver, 1 otherwise
validate_version_format() {
	local version="${1:-}"
	version="${version#v}" # Strip optional v prefix

	# SemVer 2.0.0 pattern
	local num='(0|[1-9][0-9]*)'
	local prerelease_id='(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][a-zA-Z0-9-]*)'
	local build_id='[a-zA-Z0-9-]+'

	local pattern="^${num}\\.${num}\\.${num}"
	pattern+="(-${prerelease_id}(\\.${prerelease_id})*)?"
	pattern+="(\\+${build_id}(\\.${build_id})*)?$"

	if [[ "$version" =~ $pattern ]]; then
		return 0
	fi

	return 1
}

# =============================================================================
# Export functions
# =============================================================================
export -f validate_pypi_package validate_npm_package validate_gem_package
export -f validate_version_format
