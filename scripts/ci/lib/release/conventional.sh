#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Conventional commit parsing for release automation
#
# Parses git commits following the Conventional Commits specification.

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

		# Variables are available to caller since this script is sourced
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
