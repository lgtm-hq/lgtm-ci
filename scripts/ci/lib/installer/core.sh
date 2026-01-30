#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Core installer initialization for CI tool installation scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
#   installer_init

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_CORE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_INSTALLER_CORE_LOADED=1

# =============================================================================
# Initialization
# =============================================================================

# Initialize installer environment - sources all required libraries
# Sets INSTALLER_LIB_DIR for use by callers
installer_init() {
	INSTALLER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

	# Source required libraries with fallbacks
	if [[ -f "$INSTALLER_LIB_DIR/log.sh" ]]; then
		# shellcheck source=../log.sh
		source "$INSTALLER_LIB_DIR/log.sh"
	else
		# Minimal fallback logging (matches log.sh API)
		log_info() { echo "[${TOOL_NAME:-installer}] $*"; }
		log_success() { echo "[${TOOL_NAME:-installer}] SUCCESS: $*"; }
		log_warn() { echo "[${TOOL_NAME:-installer}] WARN: $*" >&2; }
		log_warning() { log_warn "$@"; } # Alias for backwards compatibility
		log_error() { echo "[${TOOL_NAME:-installer}] ERROR: $*" >&2; }
		log_verbose() { [[ "${VERBOSE:-}" == "1" ]] && echo "[${TOOL_NAME:-installer}] $*" >&2 || true; }
	fi

	if [[ -f "$INSTALLER_LIB_DIR/platform.sh" ]]; then
		# shellcheck source=../platform.sh
		source "$INSTALLER_LIB_DIR/platform.sh"
	fi

	if [[ -f "$INSTALLER_LIB_DIR/network/download.sh" ]]; then
		# shellcheck source=../network/download.sh
		source "$INSTALLER_LIB_DIR/network/download.sh"
	fi

	if [[ -f "$INSTALLER_LIB_DIR/network/checksum.sh" ]]; then
		# shellcheck source=../network/checksum.sh
		source "$INSTALLER_LIB_DIR/network/checksum.sh"
	fi

	if [[ -f "$INSTALLER_LIB_DIR/fs.sh" ]]; then
		# shellcheck source=../fs.sh
		source "$INSTALLER_LIB_DIR/fs.sh"
	fi

	# Minimal fallbacks only for functions not provided by libraries
	# Libraries now have their own internal fallbacks, so these are last-resort
	if ! declare -f command_exists &>/dev/null; then
		command_exists() { command -v "$1" >/dev/null 2>&1; }
	fi

	if ! declare -f ensure_directory &>/dev/null; then
		ensure_directory() { [[ -d "$1" ]] || mkdir -p "$1"; }
	fi

	# Set defaults
	DRY_RUN="${DRY_RUN:-0}"
	BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_init
