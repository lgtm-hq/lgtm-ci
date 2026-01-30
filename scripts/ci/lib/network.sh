#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Network and download utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/network.sh"
#   download_with_retries "https://example.com/file" "./file"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NETWORK_LOADED=1

# Source dependencies with fallbacks
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_LGTM_CI_LIB_DIR/log.sh" ]]; then
  # shellcheck source=log.sh
  source "$_LGTM_CI_LIB_DIR/log.sh"
else
  # Fallback logging functions
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_success() { echo "[SUCCESS] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_verbose() { [[ "${VERBOSE:-0}" -eq 1 ]] && echo "[VERBOSE] $*" >&2 || true; }
fi
if [[ -f "$_LGTM_CI_LIB_DIR/fs.sh" ]]; then
  # shellcheck source=fs.sh
  source "$_LGTM_CI_LIB_DIR/fs.sh"
else
  # Fallback command_exists function
  command_exists() { command -v "$1" >/dev/null 2>&1; }
fi

# =============================================================================
# Network/port helpers
# =============================================================================

# Check if port is available (not in use)
port_available() {
  local port="$1"
  if command_exists lsof; then
    ! lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  elif command_exists nc; then
    ! nc -z 127.0.0.1 "$port" 2>/dev/null
  elif command_exists ss; then
    ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(:|])${port}$"
  else
    return 0 # Assume available if no tools found
  fi
}

# Wait for port to become available
# Usage: wait_for_port 4000 10 0.5
wait_for_port() {
  local port="${1:-4000}"
  local timeout="${2:-5}"
  local interval="${3:-0.5}"
  local elapsed=0

  log_info "Waiting for port $port to be released (timeout: ${timeout}s)..."

  while ! port_available "$port"; do
    if [[ $(awk "BEGIN {print ($elapsed >= $timeout)}") -eq 1 ]]; then
      log_warn "Port $port still in use after ${timeout}s, continuing anyway..."
      return 0
    fi
    sleep "$interval"
    elapsed=$(awk "BEGIN {print $elapsed + $interval}")
  done

  log_success "Port $port is now free"
  return 0
}

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

# Download and execute installer script securely
# Downloads to temp file first, then executes (avoids curl|bash pattern)
# Note: Uses subshell for cleanup to avoid overwriting caller's traps
# Usage: download_and_run_installer "url" [args...]
download_and_run_installer() {
  local url="$1"
  shift
  local args=("$@")

  # Use subshell to avoid overwriting caller's traps
  (
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    local script_file="$tmpdir/installer.sh"

    log_verbose "Downloading installer from: $url"
    if ! curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "$script_file"; then
      log_error "Failed to download installer script"
      exit 1
    fi

    # Basic validation - check it's a shell script
    if ! head -1 "$script_file" | grep -qE '^#!.*sh'; then
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
export -f port_available wait_for_port download_with_retries verify_checksum download_and_run_installer
