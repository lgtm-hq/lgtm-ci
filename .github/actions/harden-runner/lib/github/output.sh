#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: GitHub Actions output and environment variable helpers
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/output.sh"
#   set_github_output "version" "1.0.0"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_OUTPUT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_OUTPUT_LOADED=1

# =============================================================================
# Internal validation and multiline helpers
# =============================================================================

# Validate GitHub Actions output/env key (alphanumerics, hyphens, underscores).
_validate_github_output_key() {
	local key="$1"
	local context="${2:-set_github_output}"

	if [[ -z "$key" ]]; then
		echo "${context}: key must not be empty" >&2
		return 1
	fi
	if [[ "$key" == *$'\n'* || "$key" == *$'\r'* ]]; then
		echo "${context}: key contains invalid characters" >&2
		return 1
	fi
	if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
		echo "${context}: invalid key '$key' (use alphanumerics, hyphens, underscores)" >&2
		return 1
	fi
}

# Validate a PATH entry before appending to GITHUB_PATH.
_validate_github_path_entry() {
	local path="$1"

	if [[ -z "$path" ]]; then
		echo "add_github_path: path must not be empty" >&2
		return 1
	fi
	if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
		echo "add_github_path: path contains invalid characters" >&2
		return 1
	fi
}

# Random multiline delimiter for GITHUB_OUTPUT / GITHUB_ENV (openssl with od fallback).
_github_actions_multiline_delimiter() {
	local suffix
	suffix="$(
		openssl rand -hex 16 2>/dev/null ||
			od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
	)"
	printf 'ghadelimiter_%s' "$suffix"
}

# Append a multiline key/value block to a GitHub Actions file.
_github_write_multiline_entry() {
	local file="$1"
	local key="$2"
	local value="$3"
	local delimiter

	delimiter="$(_github_actions_multiline_delimiter)"
	{
		echo "$key<<$delimiter"
		echo "$value"
		echo "$delimiter"
	} >>"$file"
}

# =============================================================================
# GitHub Actions output/environment helpers
# =============================================================================

# Set a GitHub Actions output variable
# Usage: set_github_output "key" "value"
set_github_output() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		if ! _validate_github_output_key "$key" "set_github_output"; then
			return 1
		fi
		if [[ "$value" == *$'\n'* ]]; then
			echo "set_github_output: value for '$key' contains newline; use set_github_output_multiline" >&2
			return 1
		fi
		echo "$key=$value" >>"$GITHUB_OUTPUT"
	fi
}

# Set a multiline GitHub Actions output variable
# Usage: set_github_output_multiline "key" "multiline value"
set_github_output_multiline() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		if ! _validate_github_output_key "$key" "set_github_output_multiline"; then
			return 1
		fi
		_github_write_multiline_entry "$GITHUB_OUTPUT" "$key" "$value"
	fi
}

# Set a GitHub Actions environment variable
# Usage: set_github_env "key" "value"
set_github_env() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_ENV:-}" ]]; then
		if ! _validate_github_output_key "$key" "set_github_env"; then
			return 1
		fi
		if [[ "$value" == *$'\n'* ]]; then
			_github_write_multiline_entry "$GITHUB_ENV" "$key" "$value"
		else
			echo "$key=$value" >>"$GITHUB_ENV"
		fi
	fi
}

# Add path to GitHub Actions PATH
# Usage: add_github_path "/some/path"
add_github_path() {
	local path="$1"
	if [[ -n "${GITHUB_PATH:-}" ]]; then
		if ! _validate_github_path_entry "$path"; then
			return 1
		fi
		if [[ "$path" != /* ]]; then
			return 0
		fi
		if [[ -d "$path" ]]; then
			echo "$path" >>"$GITHUB_PATH"
		fi
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
export -f _validate_github_output_key _validate_github_path_entry
export -f _github_actions_multiline_delimiter _github_write_multiline_entry
export -f set_github_output set_github_output_multiline set_github_env add_github_path
export -f configure_git_ci_user
