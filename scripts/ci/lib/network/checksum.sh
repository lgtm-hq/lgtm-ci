#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Checksum verification utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/checksum.sh"
#   verify_checksum "file.tar.gz" "abc123..."

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_CHECKSUM_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NETWORK_CHECKSUM_LOADED=1

# Source logging if available
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$_LGTM_CI_LIB_DIR/log.sh" ]]; then
  # shellcheck source=../log.sh
  source "$_LGTM_CI_LIB_DIR/log.sh"
else
  log_verbose() { [[ "${VERBOSE:-0}" -eq 1 ]] && echo "[VERBOSE] $*" >&2 || true; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
fi

# Fallback command_exists
command_exists() { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
# Checksum verification
# =============================================================================

# Verify file checksum
# Usage: verify_checksum "file" "expected_checksum" [algorithm] [--skip-if-unavailable]
# Returns 0 if checksum matches, 1 otherwise
# By default, fails if no checksum tool is available
# Pass --skip-if-unavailable to skip verification when no tool is found
verify_checksum() {
  local file="$1"
  local expected="$2"
  local algorithm="${3:-sha256}"
  local skip_if_unavailable=0

  # Check for --skip-if-unavailable flag in any position
  for arg in "$@"; do
    if [[ "$arg" == "--skip-if-unavailable" ]]; then
      skip_if_unavailable=1
      break
    fi
  done

  if [[ ! -f "$file" ]]; then
    log_error "File not found for checksum verification: $file"
    return 1
  fi

  local actual
  case "$algorithm" in
    sha256)
      if command_exists sha256sum; then
        actual=$(sha256sum "$file" | awk '{print $1}')
      elif command_exists shasum; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
      else
        if [[ $skip_if_unavailable -eq 1 ]]; then
          log_warn "No sha256 tool available, skipping checksum verification"
          return 0
        else
          log_error "No sha256 tool available for checksum verification"
          return 1
        fi
      fi
      ;;
    sha512)
      if command_exists sha512sum; then
        actual=$(sha512sum "$file" | awk '{print $1}')
      elif command_exists shasum; then
        actual=$(shasum -a 512 "$file" | awk '{print $1}')
      else
        if [[ $skip_if_unavailable -eq 1 ]]; then
          log_warn "No sha512 tool available, skipping checksum verification"
          return 0
        else
          log_error "No sha512 tool available for checksum verification"
          return 1
        fi
      fi
      ;;
    *)
      log_error "Unsupported checksum algorithm: $algorithm"
      return 1
      ;;
  esac

  if [[ "$actual" == "$expected" ]]; then
    log_verbose "Checksum verified: $actual"
    return 0
  else
    log_error "Checksum mismatch for $file"
    log_error "  Expected: $expected"
    log_error "  Actual:   $actual"
    return 1
  fi
}

# =============================================================================
# Export functions
# =============================================================================
export -f verify_checksum
