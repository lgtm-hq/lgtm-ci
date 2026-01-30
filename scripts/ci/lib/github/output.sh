#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: GitHub Actions output and environment variable helpers
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/output.sh"
#   set_github_output "version" "1.0.0"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_OUTPUT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_OUTPUT_LOADED=1

# =============================================================================
# GitHub Actions output/environment helpers
# =============================================================================

# Set a GitHub Actions output variable
# Usage: set_github_output "key" "value"
set_github_output() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "$key=$value" >>"$GITHUB_OUTPUT"
	fi
}

# Set a multiline GitHub Actions output variable
# Usage: set_github_output_multiline "key" "multiline value"
set_github_output_multiline() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		# Use unique delimiter to prevent content collision
		# Separate declaration and assignment to avoid SC2155
		local delimiter
		delimiter="LGTM_CI_EOF_$$_$(date +%s)"
		{
			echo "$key<<$delimiter"
			echo "$value"
			echo "$delimiter"
		} >>"$GITHUB_OUTPUT"
	fi
}

# Set a GitHub Actions environment variable
# Usage: set_github_env "key" "value"
set_github_env() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_ENV:-}" ]]; then
		echo "$key=$value" >>"$GITHUB_ENV"
	fi
}

# Add path to GitHub Actions PATH
# Usage: add_github_path "/some/path"
add_github_path() {
	local path="$1"
	if [[ -n "${GITHUB_PATH:-}" ]] && [[ -d "$path" ]]; then
		echo "$path" >>"$GITHUB_PATH"
	fi
}

# Configure git user for CI commits (github-actions[bot])
configure_git_ci_user() {
	git config user.name "github-actions[bot]"
	git config user.email "github-actions[bot]@users.noreply.github.com"
}

# =============================================================================
# Export functions
# =============================================================================
export -f set_github_output set_github_output_multiline set_github_env add_github_path
export -f configure_git_ci_user
