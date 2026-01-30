#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Version checking utilities for installer scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/version.sh"
#   if installer_check_version "tool" "1.0.0"; then echo "Already installed"; fi

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_VERSION_LOADED:-}" ]] && return 0
readonly _LGTM_CI_INSTALLER_VERSION_LOADED=1

# Fallbacks
command_exists() { command -v "$1" >/dev/null 2>&1; }
log_info() { echo "[INFO] $*" >&2; }
log_success() { echo "[SUCCESS] $*" >&2; }

# =============================================================================
# Version checking
# =============================================================================

# Check if tool is already installed with correct version
# Usage: installer_check_version "tool_cmd" "desired_version" [version_cmd]
# Returns: 0 if correct version installed, 1 otherwise
installer_check_version() {
  local tool_cmd="$1"
  local desired_version="$2"
  local version_cmd="${3:---version}"

  if ! command_exists "$tool_cmd"; then
    return 1
  fi

  local current_version
  current_version=$("$tool_cmd" "$version_cmd" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

  if [[ "$current_version" == "$desired_version" ]]; then
    log_success "${tool_cmd} ${desired_version} already installed"
    return 0
  fi

  log_info "Found ${tool_cmd} ${current_version}, need ${desired_version}"
  return 1
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_check_version
