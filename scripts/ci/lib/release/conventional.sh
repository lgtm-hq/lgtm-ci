#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Conventional commit analysis for release automation
#
# Parses git commits following the Conventional Commits specification
# to determine version bumps and generate changelogs.

# Guard against multiple sourcing
[[ -n "${_RELEASE_CONVENTIONAL_LOADED:-}" ]] && return 0
readonly _RELEASE_CONVENTIONAL_LOADED=1

# Conventional commit regex pattern
# Matches: type(scope)!: description or type!: description or type: description
readonly CC_PATTERN='^([a-z]+)(\([^)]+\))?(!)?: (.+)$'

# Commit types that trigger version bumps
readonly FEAT_TYPES="feat feature"
readonly FIX_TYPES="fix bugfix hotfix"
readonly DOCS_TYPES="docs documentation"
readonly MISC_TYPES="style refactor perf test build ci chore revert"

# Parse a conventional commit message
# Usage: parse_conventional_commit "feat(scope): description"
# Sets: CC_TYPE, CC_SCOPE, CC_BREAKING, CC_DESCRIPTION
parse_conventional_commit() {
	local message="${1:-}"

	CC_TYPE=""
	CC_SCOPE=""
	CC_BREAKING=""
	CC_DESCRIPTION=""

	if [[ "$message" =~ $CC_PATTERN ]]; then
		CC_TYPE="${BASH_REMATCH[1]}"
		CC_SCOPE="${BASH_REMATCH[2]}"
		CC_BREAKING="${BASH_REMATCH[3]}"
		CC_DESCRIPTION="${BASH_REMATCH[4]}"

		# Clean up scope (remove parentheses)
		CC_SCOPE="${CC_SCOPE#(}"
		CC_SCOPE="${CC_SCOPE%)}"

		export CC_TYPE CC_SCOPE CC_BREAKING CC_DESCRIPTION
		return 0
	fi

	return 1
}

# Check if commit message indicates breaking change
# Usage: is_breaking_change "feat!: breaking" -> returns 0
is_breaking_change() {
	local message="${1:-}"

	# Check for ! indicator (type!: or type(scope)!:)
	# Use grep for complex patterns to avoid bash regex parsing issues
	if echo "$message" | grep -qE '^[a-z]+(\([^)]+\))?!:'; then
		return 0
	fi

	# Check for BREAKING CHANGE in body (full commit message)
	if [[ "$message" == *"BREAKING CHANGE"* ]]; then
		return 0
	fi

	return 1
}

# Get bump type for a commit type
# Usage: get_bump_for_type "feat" -> "minor"
get_bump_for_type() {
	local commit_type="${1:-}"

	# Features -> minor bump
	for t in $FEAT_TYPES; do
		if [[ "$commit_type" == "$t" ]]; then
			echo "minor"
			return 0
		fi
	done

	# Fixes -> patch bump
	for t in $FIX_TYPES; do
		if [[ "$commit_type" == "$t" ]]; then
			echo "patch"
			return 0
		fi
	done

	# Other types don't trigger releases by default
	echo "none"
}

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
# Output: JSON-like structure for changelog generation
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
