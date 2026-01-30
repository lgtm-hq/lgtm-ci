#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Binary download and installation utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/binary.sh"
#   installer_download_binary "url" "checksum_url" "tar.gz" "binary_name"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_BINARY_LOADED:-}" ]] && return 0
readonly _LGTM_CI_INSTALLER_BINARY_LOADED=1

# Source shared libraries
_LGTM_CI_INSTALLER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source logging (with fallbacks for standalone use)
if [[ -f "$_LGTM_CI_INSTALLER_LIB_DIR/log.sh" ]]; then
	# shellcheck source=../log.sh
	source "$_LGTM_CI_INSTALLER_LIB_DIR/log.sh"
else
	log_verbose() { [[ "${VERBOSE:-}" == "1" ]] && echo "[VERBOSE] $*" >&2 || true; }
	log_warn() { echo "[WARN] $*" >&2; }
	log_error() { echo "[ERROR] $*" >&2; }
	log_success() { echo "[SUCCESS] $*" >&2; }
fi

# Source filesystem utilities
if [[ -f "$_LGTM_CI_INSTALLER_LIB_DIR/fs.sh" ]]; then
	# shellcheck source=../fs.sh
	source "$_LGTM_CI_INSTALLER_LIB_DIR/fs.sh"
else
	ensure_directory() { [[ -d "$1" ]] || mkdir -p "$1"; }
fi

# Source network utilities
if [[ -f "$_LGTM_CI_INSTALLER_LIB_DIR/network/download.sh" ]]; then
	# shellcheck source=../network/download.sh
	source "$_LGTM_CI_INSTALLER_LIB_DIR/network/download.sh"
fi

if [[ -f "$_LGTM_CI_INSTALLER_LIB_DIR/network/checksum.sh" ]]; then
	# shellcheck source=../network/checksum.sh
	source "$_LGTM_CI_INSTALLER_LIB_DIR/network/checksum.sh"
fi

# Minimal fallbacks if libraries unavailable
if ! declare -f download_with_retries &>/dev/null; then
	download_with_retries() {
		local url="$1" out="$2" attempts="${3:-3}" i
		for ((i = 1; i <= attempts; i++)); do
			curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$out" 2>/dev/null && return 0
		done
		return 1
	}
fi

if ! declare -f verify_checksum &>/dev/null; then
	verify_checksum() {
		local file="$1" expected="$2" actual
		if command -v sha256sum &>/dev/null; then
			actual=$(sha256sum "$file" | awk '{print $1}')
		elif command -v shasum &>/dev/null; then
			actual=$(shasum -a 256 "$file" | awk '{print $1}')
		else
			# No checksum tool available - honor ALLOW_UNVERIFIED
			if [[ "${ALLOW_UNVERIFIED:-0}" == "1" ]]; then
				log_warn "No checksum tool available, skipping verification (ALLOW_UNVERIFIED=1)"
				return 0
			fi
			return 1
		fi
		[[ "$actual" == "$expected" ]]
	}
fi

# =============================================================================
# Binary installation
# =============================================================================

# Download, verify, and install a binary
# Usage: installer_download_binary URL CHECKSUM_URL ARCHIVE_TYPE [BINARY_NAME]
# ARCHIVE_TYPE: "tar.gz", "tar.xz", "zip", or "binary" (raw binary)
# BINARY_NAME defaults to $TOOL_NAME if not provided
# Returns: 0 on success, 1 on failure
# Note: Uses subshell with trap for automatic cleanup on any exit
installer_download_binary() {
	local url="$1"
	local checksum_url="${2:-}"
	local archive_type="${3:-tar.gz}"
	local binary_name="${4:-$TOOL_NAME}"

	# Use subshell for automatic cleanup via trap
	(
		local tmpdir
		# Portable mktemp with template (works on BSD/macOS/GNU)
		# Fallback to mkdir-based approach if mktemp fails
		tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/lgtm-binary.XXXXXXXXXX" 2>/dev/null) || {
			tmpdir="${TMPDIR:-/tmp}/lgtm-binary.$$.$RANDOM"
			mkdir -p "$tmpdir" || {
				log_error "Failed to create temporary directory"
				exit 1
			}
		}
		# Cleanup trap - removes tmpdir on any exit
		trap 'rm -rf "$tmpdir"' EXIT

		ensure_directory "${BIN_DIR:-$HOME/.local/bin}"

		log_verbose "Downloading from: $url"

		local archive_file="$tmpdir/archive"
		if ! download_with_retries "$url" "$archive_file" 3; then
			exit 1
		fi

		# Verify checksum if URL provided
		if [[ -n "$checksum_url" ]]; then
			local checksum_file="$tmpdir/checksums"
			if download_with_retries "$checksum_url" "$checksum_file" 3; then
				local expected_checksum
				if [[ -f "$checksum_file" ]]; then
					expected_checksum=$(grep -F "$(basename "$url")" "$checksum_file" 2>/dev/null | awk '{print $1}' | head -1)
					if [[ -z "$expected_checksum" ]]; then
						expected_checksum=$(head -1 "$checksum_file" | awk '{print $1}')
					fi
				fi

				if [[ -n "$expected_checksum" ]]; then
					if ! verify_checksum "$archive_file" "$expected_checksum"; then
						log_error "Checksum verification failed"
						exit 1
					fi
					log_verbose "Checksum verified"
				else
					if [[ "${ALLOW_UNVERIFIED:-0}" == "1" ]]; then
						log_warn "Could not parse checksum, skipping verification (ALLOW_UNVERIFIED=1)"
					else
						log_error "Could not parse checksum from $checksum_url"
						exit 1
					fi
				fi
			else
				if [[ "${ALLOW_UNVERIFIED:-0}" == "1" ]]; then
					log_warn "Could not download checksum, skipping verification (ALLOW_UNVERIFIED=1)"
				else
					log_error "Could not download checksum from $checksum_url"
					exit 1
				fi
			fi
		fi

		# Extract or copy binary
		case "$archive_type" in
		tar.gz | tgz)
			tar -xzf "$archive_file" -C "$tmpdir" 2>/dev/null || {
				log_error "tar.gz extraction failed"
				exit 1
			}
			;;
		tar.xz)
			tar -xJf "$archive_file" -C "$tmpdir" 2>/dev/null || {
				log_error "tar.xz extraction failed"
				exit 1
			}
			;;
		zip)
			unzip -q "$archive_file" -d "$tmpdir" 2>/dev/null || {
				log_error "zip extraction failed"
				exit 1
			}
			;;
		binary)
			cp "$archive_file" "$tmpdir/$binary_name"
			;;
		*)
			log_error "Unknown archive type: $archive_type"
			exit 1
			;;
		esac

		# Find and install binary
		local binary_path
		binary_path=$(find "$tmpdir" -name "$binary_name" -type f -perm -u+x 2>/dev/null | head -1)
		if [[ -z "$binary_path" ]]; then
			binary_path=$(find "$tmpdir" -name "$binary_name" -type f 2>/dev/null | head -1)
		fi

		if [[ -n "$binary_path" && -f "$binary_path" ]]; then
			cp "$binary_path" "${BIN_DIR:-$HOME/.local/bin}/$binary_name"
			chmod +x "${BIN_DIR:-$HOME/.local/bin}/$binary_name"

			# Verify binary is executable (check file is executable, not --version)
			if [[ -x "${BIN_DIR:-$HOME/.local/bin}/$binary_name" ]]; then
				log_success "${binary_name} installed to ${BIN_DIR:-$HOME/.local/bin}/$binary_name"
				exit 0
			fi
		fi

		exit 1
	)
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_download_binary
