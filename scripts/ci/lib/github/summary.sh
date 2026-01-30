#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: GitHub Actions step summary helpers
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/summary.sh"
#   add_github_summary "## Build Results"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_SUMMARY_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_SUMMARY_LOADED=1

# =============================================================================
# GitHub Actions step summary helpers
# =============================================================================

# Add content to the GitHub Actions step summary
# Usage: add_github_summary "## Results" "Some content"
add_github_summary() {
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		echo "$*" >>"$GITHUB_STEP_SUMMARY"
	fi
}

# Add a markdown table row to the step summary
# Usage: add_github_summary_row "col1" "col2" "col3"
add_github_summary_row() {
	# Early return if no columns provided (avoids shift error under set -e)
	if [[ $# -eq 0 ]]; then
		return
	fi

	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		local row="| $1"
		shift
		for col in "$@"; do
			row+=" | $col"
		done
		row+=" |"
		echo "$row" >>"$GITHUB_STEP_SUMMARY"
	fi
}

# Add a collapsible details section to the step summary
# Usage: add_github_summary_details "Summary title" "Content inside"
add_github_summary_details() {
	local summary="$1"
	local content="$2"
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		{
			echo "<details>"
			echo "<summary>$summary</summary>"
			echo ""
			echo "$content"
			echo ""
			echo "</details>"
		} >>"$GITHUB_STEP_SUMMARY"
	fi
}

# =============================================================================
# Export functions
# =============================================================================
export -f add_github_summary add_github_summary_row add_github_summary_details
