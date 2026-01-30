#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Network port utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/port.sh"
#   if port_available 3000; then echo "Port is free"; fi

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_PORT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NETWORK_PORT_LOADED=1

# Source logging if available
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$_LGTM_CI_LIB_DIR/log.sh" ]]; then
  # shellcheck source=../log.sh
  source "$_LGTM_CI_LIB_DIR/log.sh"
else
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_success() { echo "[SUCCESS] $*" >&2; }
fi

# Fallback command_exists
command_exists() { command -v "$1" >/dev/null 2>&1; }

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
# Export functions
# =============================================================================
export -f port_available wait_for_port
