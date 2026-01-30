#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Download utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/download.sh"
#   download_with_retries "https://example.com/file" "./file"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_DOWNLOAD_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NETWORK_DOWNLOAD_LOADED=1

# Source logging if available
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$_LGTM_CI_LIB_DIR/log.sh" ]]; then
  # shellcheck source=../log.sh
  source "$_LGTM_CI_LIB_DIR/log.sh"
else
  log_verbose() { [[ "${VERBOSE:-}" == "1" ]] && echo "[VERBOSE] $*" >&2 || true; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
fi

# =============================================================================
# Download helpers
# =============================================================================

# Download file with retries and exponential backoff
# Usage: download_with_retries "url" "output_file" [max_attempts]
download_with_retries() {
  local url="$1"
  local out="$2"
  local attempts="${3:-3}"
  local delay=0.5
  local i

  for ((i = 1; i <= attempts; i++)); do
    log_verbose "Download attempt $i/$attempts: $url"
    if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$out"; then
      return 0
    fi
    if [[ $i -lt $attempts ]]; then
      log_verbose "Download failed, retrying in ${delay}s..."
      sleep "$delay"
      delay=$(awk -v d="$delay" 'BEGIN{ printf "%.2f", d*2 }')
    fi
  done
  return 1
}

# Download and execute installer script securely
# Downloads to temp file first, then executes (avoids curl|bash pattern)
# Note: Uses subshell for cleanup to avoid overwriting caller's traps
# Usage: download_and_run_installer "url" [expected_checksum] [args...]
# If expected_checksum is provided, verifies the download before execution
download_and_run_installer() {
  local url="$1"
  shift
  local expected_checksum=""
  local args=()

  # Check if first arg looks like a checksum (64 hex chars for sha256)
  if [[ $# -gt 0 && "$1" =~ ^[a-fA-F0-9]{64}$ ]]; then
    expected_checksum="$1"
    shift
  fi
  args=("$@")

  # Use subshell to avoid overwriting caller's traps
  (
    local tmpdir
    # Use portable mktemp with template (works on BSD/macOS/GNU)
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/lgtm-installer.XXXXXXXXXX") || {
      log_error "Failed to create temporary directory"
      exit 1
    }
    trap 'rm -rf "$tmpdir"' EXIT

    local script_file="$tmpdir/installer.sh"

    log_verbose "Downloading installer from: $url"
    if ! curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "$script_file"; then
      log_error "Failed to download installer script"
      exit 1
    fi

    # Verify checksum if provided
    if [[ -n "$expected_checksum" ]]; then
      if declare -f verify_checksum &>/dev/null; then
        if ! verify_checksum "$script_file" "$expected_checksum" sha256; then
          log_error "Checksum verification failed for installer script"
          exit 1
        fi
        log_verbose "Installer checksum verified"
      else
        log_warn "verify_checksum not available, skipping integrity check"
      fi
    fi

    # Basic validation - check it's a shell script (bash or sh)
    if ! head -1 "$script_file" | grep -qE '^#!/.*(ba)?sh'; then
      log_warn "Downloaded file may not be a shell script"
    fi

    chmod +x "$script_file"
    log_verbose "Executing installer with args: ${args[*]:-none}"

    if [[ ${#args[@]} -gt 0 ]]; then
      "$script_file" "${args[@]}"
    else
      "$script_file"
    fi
  )
}

# =============================================================================
# Export functions
# =============================================================================
export -f download_with_retries download_and_run_installer
