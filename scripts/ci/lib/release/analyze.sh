#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Commit analysis for release automation
#
# Analyzes git commits to determine version bumps and group changes.

# Guard against multiple sourcing
[[ -n "${_RELEASE_ANALYZE_LOADED:-}" ]] && return 0
readonly _RELEASE_ANALYZE_LOADED=1

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./conventional.sh
source "$SCRIPT_DIR/conventional.sh"

# Analyze commits between two refs to determine version bump
# Usage: analyze_commits_for_bump "v1.0.0" "HEAD"
# Returns: major, minor, patch, or none
analyze_commits_for_bump() {
	local from_ref="${1:-}"
	local to_ref="${2:-HEAD}"

	local bump="none"
	local has_breaking=false
	local has_feat=false
	local has_fix=false

	# Get commit range
	local range
	if [[ -n "$from_ref" ]]; then
		range="${from_ref}..${to_ref}"
	else
		range="$to_ref"
	fi

	# Analyze each commit
	while IFS= read -r commit_line; do
		[[ -z "$commit_line" ]] && continue

		local sha="${commit_line%% *}"
		local subject="${commit_line#* }"

		# Check for breaking changes (full commit message)
		local full_message
		full_message=$(git log -1 --format='%B' "$sha" 2>/dev/null)

		if is_breaking_change "$full_message"; then
			has_breaking=true
		fi

		# Parse conventional commit
		if parse_conventional_commit "$subject"; then
			if [[ -n "$CC_BREAKING" ]]; then
				has_breaking=true
			fi

			local type_bump
			type_bump=$(get_bump_for_type "$CC_TYPE")
			if [[ "$type_bump" == "minor" ]]; then
				has_feat=true
			elif [[ "$type_bump" == "patch" ]]; then
				has_fix=true
			fi
		fi
	done < <(git log --oneline "$range" 2>/dev/null)

	# Determine final bump
	if $has_breaking; then
		echo "major"
	elif $has_feat; then
		echo "minor"
	elif $has_fix; then
		echo "patch"
	else
		echo "none"
	fi
}

# Get commits grouped by type
# Usage: get_commits_by_type "v1.0.0" "HEAD"
# Output: Sections separated by markers for changelog generation
get_commits_by_type() {
	local from_ref="${1:-}"
	local to_ref="${2:-HEAD}"

	local range
	if [[ -n "$from_ref" ]]; then
		range="${from_ref}..${to_ref}"
	else
		range="$to_ref"
	fi

	# Arrays for different types
	local -a breaking_commits=()
	local -a feat_commits=()
	local -a fix_commits=()
	local -a docs_commits=()
	local -a other_commits=()

	while IFS= read -r commit_line; do
		[[ -z "$commit_line" ]] && continue

		local sha="${commit_line%% *}"
		local subject="${commit_line#* }"

		# Get full commit for breaking change detection
		local full_message
		full_message=$(git log -1 --format='%B' "$sha" 2>/dev/null)

		local is_breaking=false
		if is_breaking_change "$full_message"; then
			is_breaking=true
		fi

		if parse_conventional_commit "$subject"; then
			local entry="${sha}|${CC_TYPE}|${CC_SCOPE}|${CC_DESCRIPTION}"

			if $is_breaking || [[ -n "$CC_BREAKING" ]]; then
				breaking_commits+=("$entry")
			fi

			case "$CC_TYPE" in
			feat | feature)
				feat_commits+=("$entry")
				;;
			fix | bugfix | hotfix)
				fix_commits+=("$entry")
				;;
			docs | documentation)
				docs_commits+=("$entry")
				;;
			*)
				other_commits+=("$entry")
				;;
			esac
		else
			# Non-conventional commit
			other_commits+=("${sha}|other||${subject}")
		fi
	done < <(git log --oneline "$range" 2>/dev/null)

	# Output as simple format (one commit per line, sections separated by markers)
	echo "### BREAKING"
	printf '%s\n' "${breaking_commits[@]}"
	echo "### FEATURES"
	printf '%s\n' "${feat_commits[@]}"
	echo "### FIXES"
	printf '%s\n' "${fix_commits[@]}"
	echo "### DOCS"
	printf '%s\n' "${docs_commits[@]}"
	echo "### OTHER"
	printf '%s\n' "${other_commits[@]}"
}

# Count commits by type between refs
# Usage: count_commits_by_type "v1.0.0" "HEAD"
count_commits_by_type() {
	local from_ref="${1:-}"
	local to_ref="${2:-HEAD}"

	local range
	if [[ -n "$from_ref" ]]; then
		range="${from_ref}..${to_ref}"
	else
		range="$to_ref"
	fi

	local breaking=0
	local feat=0
	local fix=0
	local docs=0
	local other=0

	while IFS= read -r commit_line; do
		[[ -z "$commit_line" ]] && continue

		local sha="${commit_line%% *}"
		local subject="${commit_line#* }"

		local full_message
		full_message=$(git log -1 --format='%B' "$sha" 2>/dev/null)

		if is_breaking_change "$full_message"; then
			((breaking++))
		fi

		if parse_conventional_commit "$subject"; then
			case "$CC_TYPE" in
			feat | feature) ((feat++)) ;;
			fix | bugfix | hotfix) ((fix++)) ;;
			docs | documentation) ((docs++)) ;;
			*) ((other++)) ;;
			esac
		else
			((other++))
		fi
	done < <(git log --oneline "$range" 2>/dev/null)

	echo "breaking=$breaking"
	echo "features=$feat"
	echo "fixes=$fix"
	echo "docs=$docs"
	echo "other=$other"
}

# Check if there are releasable commits
# Usage: has_releasable_commits "v1.0.0" "HEAD"
has_releasable_commits() {
	local from_ref="${1:-}"
	local to_ref="${2:-HEAD}"

	local bump
	bump=$(analyze_commits_for_bump "$from_ref" "$to_ref")

	[[ "$bump" != "none" ]]
}
