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
# Note: nc fallback only checks localhost (127.0.0.1). Ports bound to
# 0.0.0.0 or specific interfaces may be missed when lsof is unavailable.
port_available() {
	local port="$1"

	# Validate port is a valid integer in range 1-65535
	if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
		log_warn "Invalid port: $port"
		return 1
	fi

	if command_exists lsof; then
		! lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1
	elif command_exists nc; then
		# Note: Only checks localhost binding; may miss ports on other interfaces
		! nc -z 127.0.0.1 "$port" 2>/dev/null
	elif command_exists ss; then
		! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(:|])${port}$"
	else
		# No port-checking tool available - log warning and assume available
		log_warn "No port-checking tool available (lsof, nc, ss), assuming port $port is available"
		return 0
	fi
}

# Wait for port to become available
# Usage: wait_for_port 4000 10 0.5
# Note: Returns 0 even on timeout (logs warning, continues anyway) for CI resilience.
#       If strict port-free verification is needed, check the log output.
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
