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

# Fallbacks
log_verbose() { [[ "${VERBOSE:-0}" -eq 1 ]] && echo "[VERBOSE] $*" >&2 || true; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*" >&2; }
ensure_directory() { [[ -d "$1" ]] || mkdir -p "$1"; }
download_with_retries() {
  local url="$1" out="$2" attempts="${3:-3}"
  for ((i = 1; i <= attempts; i++)); do
    curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$out" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
verify_checksum() {
  local file="$1" expected="$2" actual
  if command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    return 1
  fi
  [[ "$actual" == "$expected" ]]
}

# =============================================================================
# Binary installation
# =============================================================================

# Download, verify, and install a binary
# Usage: installer_download_binary URL CHECKSUM_URL ARCHIVE_TYPE [BINARY_NAME]
# ARCHIVE_TYPE: "tar.gz", "tar.xz", "zip", or "binary" (raw binary)
# Returns: 0 on success, 1 on failure
installer_download_binary() {
  local url="$1"
  local checksum_url="${2:-}"
  local archive_type="${3:-tar.gz}"
  local binary_name="${4:-$TOOL_NAME}"

  local tmpdir
  tmpdir=$(mktemp -d)
  local cleanup_tmpdir="$tmpdir"

  ensure_directory "${BIN_DIR:-$HOME/.local/bin}"

  log_verbose "Downloading from: $url"

  local archive_file="$tmpdir/archive"
  if ! download_with_retries "$url" "$archive_file" 3; then
    rm -rf "$cleanup_tmpdir"
    return 1
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
          rm -rf "$cleanup_tmpdir"
          return 1
        fi
        log_verbose "Checksum verified"
      else
        if [[ "${ALLOW_UNVERIFIED:-0}" == "1" ]]; then
          log_warn "Could not parse checksum, skipping verification (ALLOW_UNVERIFIED=1)"
        else
          log_error "Could not parse checksum from $checksum_url"
          rm -rf "$cleanup_tmpdir"
          return 1
        fi
      fi
    else
      if [[ "${ALLOW_UNVERIFIED:-0}" == "1" ]]; then
        log_warn "Could not download checksum, skipping verification (ALLOW_UNVERIFIED=1)"
      else
        log_error "Could not download checksum from $checksum_url"
        rm -rf "$cleanup_tmpdir"
        return 1
      fi
    fi
  fi

  # Extract or copy binary
  case "$archive_type" in
    tar.gz | tgz)
      tar -xzf "$archive_file" -C "$tmpdir" 2>/dev/null || { log_error "tar.gz extraction failed"; rm -rf "$cleanup_tmpdir"; return 1; }
      ;;
    tar.xz)
      tar -xJf "$archive_file" -C "$tmpdir" 2>/dev/null || { log_error "tar.xz extraction failed"; rm -rf "$cleanup_tmpdir"; return 1; }
      ;;
    zip)
      unzip -q "$archive_file" -d "$tmpdir" 2>/dev/null || { log_error "zip extraction failed"; rm -rf "$cleanup_tmpdir"; return 1; }
      ;;
    binary)
      cp "$archive_file" "$tmpdir/$binary_name"
      ;;
    *)
      log_error "Unknown archive type: $archive_type"
      rm -rf "$cleanup_tmpdir"
      return 1
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

    if "${BIN_DIR:-$HOME/.local/bin}/$binary_name" --version &>/dev/null; then
      log_success "${binary_name} installed to ${BIN_DIR:-$HOME/.local/bin}/$binary_name"
      rm -rf "$cleanup_tmpdir"
      return 0
    fi
  fi

  rm -rf "$cleanup_tmpdir"
  return 1
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_download_binary
