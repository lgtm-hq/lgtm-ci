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
	return 0
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
	return 0
}

# Random multiline delimiter for GITHUB_OUTPUT / GITHUB_ENV (#1675): 128 bits
# from the kernel CSPRNG (/dev/urandom through od, present on the Linux and
# macOS runners and in Git for Windows), else `openssl rand`. Never falls back
# to a guessable value: with no random source it prints nothing and fails.
_github_actions_multiline_delimiter() {
	local suffix=""
	if [[ -r /dev/urandom ]]; then
		suffix="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || suffix=""
	fi
	if [[ ! "$suffix" =~ ^[0-9a-f]{32}$ ]]; then
		suffix="$(openssl rand -hex 16 2>/dev/null)" || suffix=""
	fi
	if [[ ! "$suffix" =~ ^[0-9a-f]{32}$ ]]; then
		echo "multiline output: no cryptographic random source (/dev/urandom or openssl)" >&2
		return 1
	fi
	printf 'ghadelimiter_%s' "$suffix"
}

# Append a multiline key/value block to a GitHub Actions file. The value is
# written only under a delimiter it does not contain, so it cannot end early
# and set other keys; after three collisions the write fails closed.
_github_write_multiline_entry() {
	local file="$1"
	local key="$2"
	local value="$3"
	local delimiter="" candidate attempt

	for attempt in 1 2 3; do
		candidate="$(_github_actions_multiline_delimiter)" || return 1
		if [[ "$value" != *"$candidate"* ]]; then
			delimiter="$candidate"
			break
		fi
	done
	if [[ -z "$delimiter" ]]; then
		echo "multiline output: value for '${key}' contains the generated delimiter; refusing to write it" >&2
		return 1
	fi
	{
		printf '%s\n' "$key<<$delimiter"
		printf '%s\n' "$value"
		printf '%s\n' "$delimiter"
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

# Set a multiline GitHub Actions output variable. The only supported way to
# write a multi-line value under scripts/ci: never hand-write key<<DELIM.
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
