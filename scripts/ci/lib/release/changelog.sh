#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Changelog generation utilities for release automation
#
# Generates changelogs from conventional commits in various formats.

# Guard against multiple sourcing
[[ -n "${_RELEASE_CHANGELOG_LOADED:-}" ]] && return 0
readonly _RELEASE_CHANGELOG_LOADED=1

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./analyze.sh
source "$SCRIPT_DIR/analyze.sh"

# Format a single commit entry for changelog
# Usage: format_commit_entry "abc1234" "feat" "auth" "add login" "full"
format_commit_entry() {
	local sha="${1:-}"
	local type="${2:-}"
	local scope="${3:-}"
	local description="${4:-}"
	local format="${5:-full}"

	local short_sha="${sha:0:7}"

	case "$format" in
	full)
		if [[ -n "$scope" ]]; then
			echo "- **${scope}**: ${description} (${short_sha})"
		else
			echo "- ${description} (${short_sha})"
		fi
		;;
	simple)
		echo "- ${description}"
		;;
	with-type)
		if [[ -n "$scope" ]]; then
			echo "- ${type}(${scope}): ${description}"
		else
			echo "- ${type}: ${description}"
		fi
		;;
	*)
		echo "- ${description} (${short_sha})"
		;;
	esac
}

# Generate changelog section from commits
# Usage: generate_changelog_section "Features" "feat_commits_data"
generate_changelog_section() {
	local title="${1:-}"
	local commits_data="${2:-}"
	local format="${3:-full}"

	[[ -z "$commits_data" ]] && return

	local has_content=false
	local output=""

	while IFS='|' read -r sha type scope description; do
		[[ -z "$sha" ]] && continue
		has_content=true
		output+="$(format_commit_entry "$sha" "$type" "$scope" "$description" "$format")"$'\n'
	done <<<"$commits_data"

	if $has_content; then
		echo "### ${title}"
		echo ""
		echo -n "$output"
		echo ""
	fi
}

# Generate full changelog between two refs
# Usage: generate_changelog "v1.0.0" "HEAD" "1.1.0"
generate_changelog() {
	local from_ref="${1:-}"
	local to_ref="${2:-HEAD}"
	local version="${3:-}"
	local format="${4:-full}"

	local date
	date=$(date +%Y-%m-%d)

	# Header
	if [[ -n "$version" ]]; then
		echo "## [${version}] - ${date}"
	else
		echo "## Unreleased"
	fi
	echo ""

	# Get commits grouped by type
	local commits_output
	commits_output=$(get_commits_by_type "$from_ref" "$to_ref")

	# Parse sections
	local current_section=""
	local breaking_commits=""
	local feat_commits=""
	local fix_commits=""
	local docs_commits=""
	local other_commits=""

	while IFS= read -r line; do
		case "$line" in
		"### BREAKING")
			current_section="breaking"
			;;
		"### FEATURES")
			current_section="features"
			;;
		"### FIXES")
			current_section="fixes"
			;;
		"### DOCS")
			current_section="docs"
			;;
		"### OTHER")
			current_section="other"
			;;
		*)
			[[ -z "$line" ]] && continue
			case "$current_section" in
			breaking) breaking_commits+="${line}"$'\n' ;;
			features) feat_commits+="${line}"$'\n' ;;
			fixes) fix_commits+="${line}"$'\n' ;;
			docs) docs_commits+="${line}"$'\n' ;;
			other) other_commits+="${line}"$'\n' ;;
			esac
			;;
		esac
	done <<<"$commits_output"

	# Generate sections (breaking changes first)
	generate_changelog_section "Breaking Changes" "$breaking_commits" "$format"
	generate_changelog_section "Features" "$feat_commits" "$format"
	generate_changelog_section "Bug Fixes" "$fix_commits" "$format"
	generate_changelog_section "Documentation" "$docs_commits" "$format"

	# Only include "Other" if explicitly requested
	if [[ "$format" == "full" ]] && [[ -n "$other_commits" ]]; then
		generate_changelog_section "Other Changes" "$other_commits" "$format"
	fi
}

# Generate release notes (more concise than changelog)
# Usage: generate_release_notes "v1.0.0" "HEAD" "1.1.0"
generate_release_notes() {
	local from_ref="${1:-}"
	local to_ref="${2:-HEAD}"
	local version="${3:-}"

	# Counts
	local counts
	counts=$(count_commits_by_type "$from_ref" "$to_ref")

	local breaking features fixes docs other
	eval "$counts"

	# Summary line
	local summary_parts=()
	((breaking > 0)) && summary_parts+=("${breaking} breaking change(s)")
	((features > 0)) && summary_parts+=("${features} feature(s)")
	((fixes > 0)) && summary_parts+=("${fixes} fix(es)")
	((docs > 0)) && summary_parts+=("${docs} documentation update(s)")

	if [[ ${#summary_parts[@]} -gt 0 ]]; then
		echo "This release includes: $(
			IFS=', '
			echo "${summary_parts[*]}"
		)"
		echo ""
	fi

	# Generate changelog content
	generate_changelog "$from_ref" "$to_ref" "$version" "simple"
}
