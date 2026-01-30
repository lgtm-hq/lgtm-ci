#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Formatting helpers for GitHub PR comments and summaries
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/format.sh"
#   formatted=$(format_score_with_color 95)

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_FORMAT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_FORMAT_LOADED=1

# =============================================================================
# GitHub Pages URL helpers
# =============================================================================

# Construct GitHub Pages URL for a given path
# Usage: get_github_pages_url "playwright" -> https://owner.github.io/repo/playwright/
# Usage: get_github_pages_url "lighthouse" "lgtm-hq/turbo-themes"
get_github_pages_url() {
	local path="${1:-}"
	local repo="${2:-${GITHUB_REPOSITORY:-}}"

	if [[ -z "$repo" ]]; then
		echo ""
		return 1
	fi

	local repo_owner="${repo%%/*}"
	local repo_name="${repo#*/}"

	if [[ -z "$repo_owner" || -z "$repo_name" ]]; then
		echo ""
		return 1
	fi

	# Normalize owner to lowercase for GitHub Pages domain
	local repo_owner_lower
	repo_owner_lower=$(echo "$repo_owner" | tr '[:upper:]' '[:lower:]')
	local repo_name_lower
	repo_name_lower=$(echo "$repo_name" | tr '[:upper:]' '[:lower:]')

	# Handle user pages repos (repo name equals owner.github.io)
	local base_url
	if [[ "$repo_name_lower" == "${repo_owner_lower}.github.io" ]]; then
		base_url="https://${repo_owner_lower}.github.io"
	else
		base_url="https://${repo_owner_lower}.github.io/${repo_name}"
	fi

	if [[ -n "$path" ]]; then
		echo "${base_url}/${path}/"
	else
		echo "${base_url}/"
	fi
}

# =============================================================================
# Score formatting helpers for PR comments
# =============================================================================

# Get score emoji based on threshold
# Usage: score_emoji 85 80 -> "🟢" (score meets threshold)
# Returns: 🟢 if >= threshold, 🟡 if within 10 points, 🔴 otherwise
score_emoji() {
	local score="$1"
	local threshold="${2:-80}"
	local warn=$((threshold - 10))
	((warn < 0)) && warn=0

	if [[ $score -ge $threshold ]]; then
		echo "🟢"
	elif [[ $score -ge $warn ]]; then
		echo "🟡"
	else
		echo "🔴"
	fi
}

# Format a numeric score with color-coded emoji indicator
# Usage: format_score_with_color 95 -> "🟢 95"
# Usage: format_score_with_color 75 80 -> "🔴 75" (custom threshold)
# Thresholds: 🟢 >= 90, 🟡 >= threshold (default 80), 🔴 < threshold
format_score_with_color() {
	local score="$1"
	local threshold="${2:-80}"

	if [[ "$score" == "N/A" || -z "$score" ]]; then
		echo "⚪ N/A"
	elif [[ "$score" -ge 90 ]] 2>/dev/null; then
		echo "🟢 $score"
	elif [[ "$score" -ge "$threshold" ]] 2>/dev/null; then
		echo "🟡 $score"
	else
		echo "🔴 $score"
	fi
}

# Format a percentage with color-coded emoji indicator
# Usage: format_percentage_with_color 95.5 -> "🟢 95.5%"
# Note: Uses awk for float comparisons (POSIX-compatible, no bc dependency)
format_percentage_with_color() {
	local pct="$1"
	local threshold="${2:-80}"

	# Handle N/A or empty
	if [[ "$pct" == "N/A" || -z "$pct" ]]; then
		echo "⚪ N/A"
		return
	fi

	# Validate inputs - pct must be numeric (integer or float)
	if ! [[ "$pct" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
		echo "⚪ N/A"
		return
	fi

	# Validate threshold is numeric
	if ! [[ "$threshold" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
		threshold=80
	fi

	# Use awk -v to safely pass variables (POSIX-compatible, no shell injection)
	if awk -v pct="$pct" 'BEGIN { exit !(pct + 0 >= 90) }' 2>/dev/null; then
		echo "🟢 ${pct}%"
	elif awk -v pct="$pct" -v threshold="$threshold" 'BEGIN { exit !(pct + 0 >= threshold + 0) }' 2>/dev/null; then
		echo "🟡 ${pct}%"
	else
		echo "🔴 ${pct}%"
	fi
}

# =============================================================================
# Export functions
# =============================================================================
export -f get_github_pages_url score_emoji format_score_with_color format_percentage_with_color
