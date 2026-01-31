#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Homebrew formula generation utilities
#
# Provides functions to generate and update Homebrew formulas for Python packages.

# Guard against multiple sourcing
[[ -n "${_PUBLISH_HOMEBREW_LOADED:-}" ]] && return 0
readonly _PUBLISH_HOMEBREW_LOADED=1

# Source registry functions if not already loaded
if [[ -z "${_PUBLISH_REGISTRY_LOADED:-}" ]]; then
	_HOMEBREW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=registry.sh
	source "$_HOMEBREW_LIB_DIR/registry.sh"
fi

# Generate a Homebrew formula from PyPI package
# Usage: generate_formula_from_pypi "package-name" "1.2.3" "Formula description" [test-pypi] [homepage] [license]
# Outputs formula content to stdout
generate_formula_from_pypi() {
	local package="${1:?Package name required}"
	local version="${2:?Version required}"
	local description="${3:-A Python package}"
	local test_pypi="${4:-false}"
	local homepage="${5:-}"
	local license="${6:-}"

	# Get download URL and SHA256
	local download_url sha256
	download_url=$(get_pypi_download_url "$package" "$version" "$test_pypi")
	if [[ -z "$download_url" ]]; then
		log_error "Could not get download URL for $package@$version"
		return 1
	fi

	sha256=$(get_pypi_sha256 "$package" "$version" "$test_pypi")
	if [[ -z "$sha256" ]]; then
		log_error "Could not get SHA256 for $package@$version"
		return 1
	fi

	# Generate formula class name (CamelCase)
	local class_name
	class_name=$(echo "$package" | sed 's/-/_/g' | awk -F_ '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' OFS='')
	# Ruby class names cannot start with a digit
	if [[ "$class_name" =~ ^[0-9] ]]; then
		class_name="Pkg$class_name"
	fi

	# Set homepage
	if [[ -z "$homepage" ]]; then
		homepage="https://pypi.org/project/$package/"
	fi

	# Try to get license from PyPI if not provided
	if [[ -z "$license" ]]; then
		local api_url="$PYPI_API_URL"
		if [[ "$test_pypi" == "true" ]]; then
			api_url="$TEST_PYPI_API_URL"
		fi
		license=$(curl -s "$api_url/$package/$version/json" 2>/dev/null |
			grep -o '"license":"[^"]*"' | head -1 | sed 's/"license":"\([^"]*\)"/\1/')
		# Default to MIT if not found or empty
		if [[ -z "$license" ]] || [[ "$license" == "null" ]]; then
			license="MIT"
		fi
	fi

	# Output formula
	cat <<EOF
# frozen_string_literal: true

class $class_name < Formula
  include Language::Python::Virtualenv

  desc "$description"
  homepage "$homepage"
  url "$download_url"
  sha256 "$sha256"
  license "$license"

  depends_on "python@3.12"

  def install
    virtualenv_install_with_resources
  end

  test do
    system bin/"$package", "--version"
  end
end
EOF
}

# Update version and SHA256 in existing Homebrew formula
# Usage: update_formula_version "formula_path" "new_version" "new_url" "new_sha256"
# Returns 0 on success, 1 on failure
update_formula_version() {
	local formula_path="${1:?Formula path required}"
	local new_version="${2:?New version required}"
	local new_url="${3:?New URL required}"
	local new_sha256="${4:?New SHA256 required}"

	if [[ ! -f "$formula_path" ]]; then
		log_error "Formula not found: $formula_path"
		return 1
	fi

	# Create backup
	cp "$formula_path" "$formula_path.bak"

	# Update URL (with atomic error handling)
	if ! sed -i.tmp "s|url \"[^\"]*\"|url \"$new_url\"|" "$formula_path"; then
		mv "$formula_path.bak" "$formula_path"
		log_error "Failed to update URL"
		return 1
	fi
	rm -f "$formula_path.tmp"

	# Update SHA256
	if ! sed -i.tmp "s|sha256 \"[^\"]*\"|sha256 \"$new_sha256\"|" "$formula_path"; then
		mv "$formula_path.bak" "$formula_path"
		log_error "Failed to update SHA256"
		return 1
	fi
	rm -f "$formula_path.tmp"

	# Clean up backup on success
	rm -f "$formula_path.bak"

	log_success "Updated formula to version $new_version"
	return 0
}

# Calculate SHA256 for a URL (downloads and hashes)
# Usage: calculate_sha256_from_url "https://..."
# Returns SHA256 hash
calculate_sha256_from_url() {
	local url="${1:?URL required}"
	local tmpfile

	tmpfile=$(mktemp)
	trap 'rm -f "$tmpfile"' RETURN

	if ! curl -sL "$url" -o "$tmpfile"; then
		log_error "Failed to download: $url"
		return 1
	fi

	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$tmpfile" | awk '{print $1}'
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$tmpfile" | awk '{print $1}'
	else
		log_error "No SHA256 tool available"
		return 1
	fi
}

# Generate resource blocks for Python dependencies
# Usage: calculate_resource_checksums "requirements.txt"
# Outputs Homebrew resource blocks
calculate_resource_checksums() {
	local requirements_file="${1:?Requirements file required}"

	if [[ ! -f "$requirements_file" ]]; then
		log_error "Requirements file not found: $requirements_file"
		return 1
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		# Skip comments and empty lines
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line// /}" ]] && continue

		# Parse package==version
		local pkg_spec="$line"
		local pkg_name pkg_version

		if [[ "$pkg_spec" =~ ^([^=<>!]+)==([^,]+) ]]; then
			pkg_name="${BASH_REMATCH[1]}"
			pkg_version="${BASH_REMATCH[2]}"
		else
			continue
		fi

		# Clean package name
		pkg_name="${pkg_name// /}"

		# Get PyPI info
		local url sha256
		url=$(get_pypi_download_url "$pkg_name" "$pkg_version")
		sha256=$(get_pypi_sha256 "$pkg_name" "$pkg_version")

		if [[ -n "$url" ]] && [[ -n "$sha256" ]]; then
			cat <<EOF

  resource "$pkg_name" do
    url "$url"
    sha256 "$sha256"
  end
EOF
		fi
	done <"$requirements_file"
}

# Clone a Homebrew tap repository
# Usage: clone_homebrew_tap "owner/repo" "target_dir"
# Returns 0 on success
clone_homebrew_tap() {
	local tap_repo="${1:?Tap repository required (owner/repo)}"
	local target_dir="${2:?Target directory required}"

	local repo_url="https://github.com/$tap_repo.git"

	if [[ -d "$target_dir/.git" ]]; then
		log_info "Updating existing tap clone..."
		git -C "$target_dir" fetch origin
		git -C "$target_dir" reset --hard origin/main 2>/dev/null ||
			git -C "$target_dir" reset --hard origin/master
	else
		log_info "Cloning tap repository..."
		git clone --depth 1 "$repo_url" "$target_dir"
	fi

	return 0
}

# Commit and push formula update
# Usage: commit_formula_update "tap_dir" "formula_name" "version"
# Returns 0 on success
commit_formula_update() {
	local tap_dir="${1:?Tap directory required}"
	local formula_name="${2:?Formula name required}"
	local version="${3:?Version required}"

	cd "$tap_dir" || return 1

	# Configure git for CI
	if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
		git config user.name "github-actions[bot]"
		git config user.email "github-actions[bot]@users.noreply.github.com"
	fi

	# Add and commit
	git add "Formula/$formula_name.rb" 2>/dev/null || git add "$formula_name.rb"

	if ! git diff --cached --quiet; then
		git commit -m "Update $formula_name to $version"
		log_success "Committed formula update"
		return 0
	else
		log_warn "No changes to commit"
		return 0
	fi
}

# =============================================================================
# Export functions
# =============================================================================
export -f generate_formula_from_pypi update_formula_version
export -f calculate_sha256_from_url calculate_resource_checksums
export -f clone_homebrew_tap commit_formula_update
