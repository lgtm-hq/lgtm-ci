#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: File system utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/fs.sh"
#   ensure_directory "./dist"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_FS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_FS_LOADED=1

# Source logging if available
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_LGTM_CI_LIB_DIR/log.sh" ]]; then
	# shellcheck source=log.sh
	source "$_LGTM_CI_LIB_DIR/log.sh"
fi

# Fallback die function if log.sh wasn't sourced or doesn't provide die
if ! declare -f die &>/dev/null; then
	die() {
		echo "[ERROR] $*" >&2
		exit 1
	}
fi

# =============================================================================
# File system helpers
# =============================================================================

# Check if command exists
command_exists() {
	command -v "$1" >/dev/null 2>&1
}

# Require command to exist or die
require_command() {
	local cmd="$1"
	local install_hint="${2:-}"
	if ! command_exists "$cmd"; then
		if [[ -n "$install_hint" ]]; then
			die "Required command not found: $cmd. $install_hint"
		else
			die "Required command not found: $cmd"
		fi
	fi
}

# Ensure directory exists, create if not
ensure_directory() {
	local dir="$1"
	if [[ ! -d "$dir" ]]; then
		if command -v log_info &>/dev/null; then
			log_info "Creating directory: $dir"
		fi
		mkdir -p "$dir"
	fi
}

# Require file to exist or die
require_file() {
	local file="$1"
	if [[ ! -f "$file" ]]; then
		die "Required file not found: $file"
	fi
}

# Check if file exists and log result (non-fatal)
check_file_exists() {
	local file="$1"
	local description="${2:-File}"

	if [[ -f "$file" ]]; then
		if command -v log_success &>/dev/null; then
			log_success "$description found: $file"
			log_verbose "File size: $(wc -c <"$file") bytes"
		fi
		return 0
	else
		if command -v log_warn &>/dev/null; then
			log_warn "$description not found: $file"
		fi
		return 1
	fi
}

# Check if directory exists and log result (non-fatal)
check_dir_exists() {
	local dir="$1"
	local description="${2:-Directory}"

	if [[ -d "$dir" ]]; then
		if command -v log_success &>/dev/null; then
			log_success "$description found: $dir"
		fi
		return 0
	else
		if command -v log_warn &>/dev/null; then
			log_warn "$description not found: $dir"
		fi
		return 1
	fi
}

# Create a temporary directory with automatic cleanup on exit
# Usage: tmpdir=$(create_temp_dir)
# Note: Preserves existing EXIT traps and uses portable mktemp
create_temp_dir() {
	local tmpdir
	# Use portable mktemp with template (works on BSD/macOS/GNU)
	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/lgtm-ci.XXXXXXXXXX") || {
		echo "[ERROR] Failed to create temporary directory" >&2
		return 1
	}

	# Capture existing EXIT trap to preserve it
	local existing_trap
	existing_trap=$(trap -p EXIT | sed "s/trap -- '\(.*\)' EXIT/\1/" || true)

	# Install new trap that cleans up tmpdir and calls existing handler
	# SC2064: We intentionally expand $tmpdir NOW (at definition time) so the
	# trap removes the correct directory, not whatever $tmpdir might be later
	# shellcheck disable=SC2064
	if [[ -n "$existing_trap" ]]; then
		trap "rm -rf '$tmpdir'; $existing_trap" EXIT
	else
		trap "rm -rf '$tmpdir'" EXIT
	fi

	echo "$tmpdir"
}

# =============================================================================
# Export functions
# =============================================================================
export -f command_exists require_command
export -f ensure_directory require_file check_file_exists check_dir_exists
export -f create_temp_dir
