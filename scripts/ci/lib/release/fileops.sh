#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Changelog file operations for release automation
#
# Functions for updating CHANGELOG.md and generating URLs.

# Guard against multiple sourcing
[[ -n "${_RELEASE_FILEOPS_LOADED:-}" ]] && return 0
readonly _RELEASE_FILEOPS_LOADED=1

# Update CHANGELOG.md file
# Usage: update_changelog_file "CHANGELOG.md" "new_content" "1.1.0"
update_changelog_file() {
	local file="${1:-CHANGELOG.md}"
	local new_content="${2:-}"
	local version="${3:-}"

	if [[ ! -f "$file" ]]; then
		# Create new changelog
		cat >"$file" <<EOF
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

${new_content}
EOF
	else
		# Create temp file in same directory for atomic mv
		local file_dir
		file_dir=$(dirname "$file")
		local temp_file
		temp_file=$(mktemp "${file_dir}/.changelog.XXXXXX")

		# Save existing EXIT trap and set cleanup trap
		local prev_trap
		prev_trap=$(trap -p EXIT | sed "s/trap -- '\\(.*\\)' EXIT/\\1/" || true)

		__fileops_cleanup_temp() {
			rm -f "$temp_file"
			# Restore previous trap if it existed
			if [[ -n "$prev_trap" ]]; then
				eval "$prev_trap"
			fi
		}
		trap __fileops_cleanup_temp EXIT

		# Find insertion point (after header section)
		# Handle case where file starts with version header (## [x.y.z])
		local header_end=0
		local line_num=0
		local first_line_is_version=false

		while IFS= read -r line; do
			((line_num++))
			if [[ "$line" =~ ^##[[:space:]] ]]; then
				if ((line_num == 1)); then
					# First line is a version header - prepend new content
					first_line_is_version=true
					break
				else
					# Found version header after header section
					header_end=$((line_num - 1))
					break
				fi
			fi
		done <"$file"

		if $first_line_is_version; then
			# File starts with version header - prepend new content
			{
				echo "$new_content"
				echo ""
				cat "$file"
			} >"$temp_file"
		elif ((header_end == 0)); then
			# No existing version sections, append after file
			cat "$file" >"$temp_file"
			echo "" >>"$temp_file"
			echo "$new_content" >>"$temp_file"
		else
			# Insert before first version section
			{
				head -n "$header_end" "$file"
				echo ""
				echo "$new_content"
				tail -n +"$((header_end + 1))" "$file"
			} >"$temp_file"
		fi

		# Preserve original file permissions
		chmod --reference="$file" "$temp_file" 2>/dev/null || chmod "$(stat -f '%Lp' "$file" 2>/dev/null || echo '644')" "$temp_file"

		mv "$temp_file" "$file"

		# Restore previous trap (cleanup trap no longer needed)
		trap - EXIT
		if [[ -n "$prev_trap" ]]; then
			# shellcheck disable=SC2064 # Intentional: restore saved trap content
			trap "$prev_trap" EXIT
		fi

		# Clean up the helper function from global scope
		unset -f __fileops_cleanup_temp
	fi
}

# Generate compare URL for GitHub
# Usage: generate_compare_url "owner/repo" "v1.0.0" "v1.1.0"
generate_compare_url() {
	local repo="${1:-}"
	local from_tag="${2:-}"
	local to_tag="${3:-}"

	if [[ -z "$repo" ]] || [[ -z "$from_tag" ]] || [[ -z "$to_tag" ]]; then
		return 1
	fi

	echo "https://github.com/${repo}/compare/${from_tag}...${to_tag}"
}
