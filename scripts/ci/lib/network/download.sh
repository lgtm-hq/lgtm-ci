#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Download utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/download.sh"
#   download_with_retries "https://example.com/file" "./file"
#
# Security model:
#   All downloads enforce a TLS floor (HTTPS-only, TLS >= 1.2) and reject
#   protocol downgrades in redirects. Two opt-in, defense-in-depth knobs are
#   supported via environment variables (defaults unchanged when unset):
#     LGTM_CI_CA_BUNDLE      Path to a custom CA bundle (curl --cacert)
#     LGTM_CI_PINNED_PUBKEY  Pinned public key (curl --pinnedpubkey), either
#                            a "sha256//BASE64" hash or a path to a PEM/DER
#                            public key file
#   For explicit caller-supplied pins use download_with_pinning, which fails
#   closed when no pin is available. Pins are the caller's responsibility to
#   rotate; this library deliberately does not ship a hard-coded pin registry.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_DOWNLOAD_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NETWORK_DOWNLOAD_LOADED=1

# Source logging if available
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"
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

# Build hardened curl arguments into the global array _LGTM_CI_CURL_ARGS.
# Enforces HTTPS-only + TLS >= 1.2, and appends opt-in CA bundle / pinned
# public key options from the environment (see security model above).
# Usage: _lgtm_ci_build_curl_args [max_time]
# Returns 1 (fail closed) if LGTM_CI_CA_BUNDLE is set but not a readable file.
_lgtm_ci_build_curl_args() {
	local max_time="${1:-300}"
	_LGTM_CI_CURL_ARGS=(
		-fsSL
		--proto '=https'
		--tlsv1.2
		--connect-timeout 30
		--max-time "$max_time"
	)
	if [[ -n "${LGTM_CI_CA_BUNDLE:-}" ]]; then
		if [[ ! -r "$LGTM_CI_CA_BUNDLE" ]]; then
			log_error "CA bundle not readable: $LGTM_CI_CA_BUNDLE"
			return 1
		fi
		_LGTM_CI_CURL_ARGS+=(--cacert "$LGTM_CI_CA_BUNDLE")
	fi
	if [[ -n "${LGTM_CI_PINNED_PUBKEY:-}" ]]; then
		_LGTM_CI_CURL_ARGS+=(--pinnedpubkey "$LGTM_CI_PINNED_PUBKEY")
	fi
	return 0
}

# Download file with retries and exponential backoff
# Usage: download_with_retries "url" "output_file" [max_attempts]
download_with_retries() {
	local url="$1"
	local out="$2"
	local attempts="${3:-3}"
	local delay=0.5
	local i

	_lgtm_ci_build_curl_args 300 || return 1

	for ((i = 1; i <= attempts; i++)); do
		log_verbose "Download attempt $i/$attempts: $url"
		if curl "${_LGTM_CI_CURL_ARGS[@]}" "$url" -o "$out"; then
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

		_lgtm_ci_build_curl_args 120 || exit 1

		log_verbose "Downloading installer from: $url"
		if ! curl "${_LGTM_CI_CURL_ARGS[@]}" "$url" -o "$script_file"; then
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

# Download a file with an explicit pinned public key (fails closed).
# Unlike download_with_retries (where pinning is an env opt-in), this
# function requires a pin: it errors out rather than silently downloading
# unpinned. Intended for high-value artifacts (installers, signing keys).
# Usage: download_with_pinning "url" "output_file" [pinned_key] [ca_bundle]
#   pinned_key  curl --pinnedpubkey value ("sha256//BASE64" or key file path);
#               falls back to $LGTM_CI_PINNED_PUBKEY when omitted
#   ca_bundle   optional custom CA bundle path (curl --cacert);
#               falls back to $LGTM_CI_CA_BUNDLE when omitted
download_with_pinning() {
	local url="$1"
	local out="$2"
	local pinned_key="${3:-${LGTM_CI_PINNED_PUBKEY:-}}"
	local ca_bundle="${4:-${LGTM_CI_CA_BUNDLE:-}}"

	if [[ -z "$pinned_key" ]]; then
		log_error "download_with_pinning: no pinned public key provided" \
			"(argument or LGTM_CI_PINNED_PUBKEY); refusing unpinned download"
		return 1
	fi
	# A pin that is a file path must exist; hash pins use the sha256// prefix
	if [[ "$pinned_key" != sha256//* && ! -r "$pinned_key" ]]; then
		log_error "download_with_pinning: pinned key file not readable: $pinned_key"
		return 1
	fi

	LGTM_CI_PINNED_PUBKEY="$pinned_key" LGTM_CI_CA_BUNDLE="$ca_bundle" \
		download_with_retries "$url" "$out"
}

# =============================================================================
# Export functions
# =============================================================================
export -f _lgtm_ci_build_curl_args download_with_retries \
	download_and_run_installer download_with_pinning
