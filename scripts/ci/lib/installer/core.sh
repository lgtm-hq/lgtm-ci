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
# Sets INSTALLER_LIB_DIR and INSTALLER_SCRIPT_DIR
installer_init() {
  INSTALLER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # Source required libraries with fallbacks
  if [[ -f "$INSTALLER_LIB_DIR/log.sh" ]]; then
    # shellcheck source=../log.sh
    source "$INSTALLER_LIB_DIR/log.sh"
  else
    # Minimal fallback logging
    log_info() { echo "[${TOOL_NAME:-installer}] $*"; }
    log_success() { echo "[${TOOL_NAME:-installer}] SUCCESS: $*"; }
    log_warn() { echo "[${TOOL_NAME:-installer}] WARN: $*" >&2; }
    log_error() { echo "[${TOOL_NAME:-installer}] ERROR: $*" >&2; }
    log_verbose() { [[ "${VERBOSE:-0}" -eq 1 ]] && echo "[${TOOL_NAME:-installer}] $*" >&2 || true; }
  fi

  if [[ -f "$INSTALLER_LIB_DIR/platform.sh" ]]; then
    # shellcheck source=../platform.sh
    source "$INSTALLER_LIB_DIR/platform.sh"
  fi

  if [[ -f "$INSTALLER_LIB_DIR/network/download.sh" ]]; then
    source "$INSTALLER_LIB_DIR/network/download.sh"
  fi

  if [[ -f "$INSTALLER_LIB_DIR/network/checksum.sh" ]]; then
    source "$INSTALLER_LIB_DIR/network/checksum.sh"
  fi

  if [[ -f "$INSTALLER_LIB_DIR/fs.sh" ]]; then
    # shellcheck source=../fs.sh
    source "$INSTALLER_LIB_DIR/fs.sh"
  fi

  # Fallback for missing fs.sh
  if ! declare -f command_exists &>/dev/null; then
    command_exists() { command -v "$1" >/dev/null 2>&1; }
  fi

  # Fallback for missing network/download.sh
  if ! declare -f download_with_retries &>/dev/null; then
    download_with_retries() {
      local url="$1" out="$2" attempts="${3:-3}" delay_ms=500 i
      for ((i = 1; i <= attempts; i++)); do
        if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$out" 2>/dev/null; then
          return 0
        fi
        if [[ $i -lt $attempts ]]; then
          sleep "$(awk "BEGIN {printf \"%.1f\", $delay_ms/1000}")"
          delay_ms=$((delay_ms * 2))
        fi
      done
      return 1
    }
  fi

  # Fallback for missing network/checksum.sh
  if ! declare -f verify_checksum &>/dev/null; then
    verify_checksum() {
      local file="$1" expected="$2" actual

      if [[ "${SKIP_CHECKSUM:-0}" == "1" ]]; then
        log_warn "Checksum verification skipped (SKIP_CHECKSUM=1) - NOT RECOMMENDED"
        return 0
      fi

      if command_exists sha256sum; then
        actual=$(sha256sum "$file" | awk '{print $1}')
      elif command_exists shasum; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
      else
        log_error "No checksum tool available (sha256sum or shasum required)"
        return 1
      fi
      [[ "$actual" == "$expected" ]]
    }
  fi

  if ! declare -f ensure_directory &>/dev/null; then
    ensure_directory() {
      local dir="$1"
      [[ -d "$dir" ]] || mkdir -p "$dir"
    }
  fi

  # Set defaults
  DRY_RUN="${DRY_RUN:-0}"
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_init
