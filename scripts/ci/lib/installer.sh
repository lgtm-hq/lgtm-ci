#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Shared installer framework for CI tool installation scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/installer.sh"
#   TOOL_NAME="mytool"
#   TOOL_DESC="My tool description"
#   TOOL_VERSION="1.0.0"
#   installer_init
#   installer_parse_args "$@"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_LOADED:-}" ]] && return 0
readonly _LGTM_CI_INSTALLER_LOADED=1

# =============================================================================
# Initialization
# =============================================================================

# Initialize installer environment - sources all required libraries
# Sets INSTALLER_LIB_DIR and INSTALLER_SCRIPT_DIR
installer_init() {
  INSTALLER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # INSTALLER_SCRIPT_DIR should be set by the calling script before calling installer_init

  # Source required libraries with fallbacks
  if [[ -f "$INSTALLER_LIB_DIR/log.sh" ]]; then
    # shellcheck source=log.sh
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
    # shellcheck source=platform.sh
    source "$INSTALLER_LIB_DIR/platform.sh"
  fi

  if [[ -f "$INSTALLER_LIB_DIR/network.sh" ]]; then
    # shellcheck source=network.sh
    source "$INSTALLER_LIB_DIR/network.sh"
  fi

  if [[ -f "$INSTALLER_LIB_DIR/fs.sh" ]]; then
    # shellcheck source=fs.sh
    source "$INSTALLER_LIB_DIR/fs.sh"
  fi

  # Fallback for missing fs.sh
  if ! declare -f command_exists &>/dev/null; then
    command_exists() { command -v "$1" >/dev/null 2>&1; }
  fi

  # Fallback for missing network.sh
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

  if ! declare -f verify_checksum &>/dev/null; then
    verify_checksum() {
      local file="$1" expected="$2" algorithm="${3:-sha256}" actual

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
        log_error "Set SKIP_CHECKSUM=1 to bypass verification (not recommended)"
        return 1
      fi
      [[ "$actual" == "$expected" ]]
    }
  fi

  if ! declare -f download_and_run_installer &>/dev/null; then
    download_and_run_installer() {
      local url="$1"
      shift
      local tmpfile
      tmpfile=$(mktemp)
      trap 'rm -f "$tmpfile"' RETURN
      if curl -fsSL "$url" -o "$tmpfile"; then
        sh "$tmpfile" "$@"
      else
        return 1
      fi
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
# Argument parsing
# =============================================================================

# Show help message generated from TOOL_* variables
installer_show_help() {
  local version_info=""
  local upper_name=""
  local help_text=""

  if [[ -n "${TOOL_VERSION:-}" ]]; then
    version_info=" (default: ${TOOL_VERSION})"
    upper_name=$(echo "${TOOL_NAME:-TOOL}" | tr '[:lower:]' '[:upper:]')
  fi

  help_text="${TOOL_DESC:-Install ${TOOL_NAME:-tool}}.

Usage:
  install-${TOOL_NAME:-tool}.sh [--help] [--dry-run]${TOOL_VERSION:+ [--version VERSION]}

Options:
  --help, -h       Show this help message
  --dry-run        Show what would be done without executing"

  if [[ -n "${TOOL_VERSION:-}" ]]; then
    help_text+="
  --version VER    Version to install${version_info}

Environment Variables:
  ${upper_name}_VERSION   Version to install"
  fi

  help_text+="
  BIN_DIR            Installation directory (default: ~/.local/bin)"

  if [[ -n "${TOOL_EXTRA_HELP:-}" ]]; then
    help_text+="

${TOOL_EXTRA_HELP}"
  fi

  echo "$help_text"
}

# Parse standard installer arguments
installer_parse_args() {
  INSTALLER_ARGS=()

  for arg in "$@"; do
    if [[ "$arg" == "--help" ]] || [[ "$arg" == "-h" ]]; then
      installer_show_help
      exit 0
    fi
  done

  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --version)
        if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
          log_error "--version requires a version argument"
          exit 1
        fi
        TOOL_VERSION="$2"
        shift 2
        ;;
      -*)
        log_warn "Unknown option: $1"
        shift
        ;;
      *)
        INSTALLER_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# =============================================================================
# Version checking
# =============================================================================

# Check if tool is already installed with correct version
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
# Binary installation
# =============================================================================

# Download, verify, and install a binary
installer_download_binary() {
  local url="$1"
  local checksum_url="${2:-}"
  local archive_type="${3:-tar.gz}"
  local binary_name="${4:-$TOOL_NAME}"

  local tmpdir
  tmpdir=$(mktemp -d)
  local cleanup_tmpdir="$tmpdir"

  ensure_directory "$BIN_DIR"

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
        if ! verify_checksum "$archive_file" "$expected_checksum" sha256; then
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
      if ! tar -xzf "$archive_file" -C "$tmpdir" 2>/dev/null; then
        log_error "tar.gz extraction failed"
        rm -rf "$cleanup_tmpdir"
        return 1
      fi
      ;;
    tar.xz)
      if ! tar -xJf "$archive_file" -C "$tmpdir" 2>/dev/null; then
        log_error "tar.xz extraction failed"
        rm -rf "$cleanup_tmpdir"
        return 1
      fi
      ;;
    zip)
      if ! unzip -q "$archive_file" -d "$tmpdir" 2>/dev/null; then
        log_error "zip extraction failed"
        rm -rf "$cleanup_tmpdir"
        return 1
      fi
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
    cp "$binary_path" "$BIN_DIR/$binary_name"
    chmod +x "$BIN_DIR/$binary_name"

    if "$BIN_DIR/$binary_name" --version &>/dev/null; then
      log_success "${binary_name} installed to $BIN_DIR/$binary_name"
      rm -rf "$cleanup_tmpdir"
      return 0
    fi
  fi

  rm -rf "$cleanup_tmpdir"
  return 1
}

# =============================================================================
# Fallback installers
# =============================================================================

installer_fallback_go() {
  local package="$1"
  if ! command_exists go; then
    log_verbose "go not available for fallback"
    return 1
  fi
  log_info "Trying go install..."
  if go install "$package" 2>/dev/null; then
    log_success "${TOOL_NAME} installed via go install"
    return 0
  fi
  return 1
}

installer_fallback_brew() {
  local formula="$1"
  local cask_flag="${2:-}"
  if ! command_exists brew; then
    log_verbose "brew not available for fallback"
    return 1
  fi
  log_warn "Homebrew fallback may install different version than requested"
  log_info "Trying Homebrew installation..."
  local brew_args=("install")
  [[ "$cask_flag" == "--cask" ]] && brew_args+=("--cask")
  brew_args+=("$formula")
  if brew "${brew_args[@]}" 2>/dev/null; then
    log_success "${TOOL_NAME} installed via Homebrew"
    return 0
  fi
  return 1
}

installer_fallback_cargo() {
  local package="$1"
  if ! command_exists cargo; then
    log_verbose "cargo not available for fallback"
    return 1
  fi
  log_info "Trying cargo install..."
  if cargo install "$package" 2>/dev/null; then
    log_success "${TOOL_NAME} installed via cargo"
    return 0
  fi
  return 1
}

# =============================================================================
# Installation chain execution
# =============================================================================

installer_run_chain() {
  local method
  for method in "$@"; do
    if eval "$method"; then
      return 0
    fi
  done
  log_error "Failed to install ${TOOL_NAME}"
  return 1
}

installer_run() {
  local install_func="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[DRY-RUN] Would install ${TOOL_NAME}${TOOL_VERSION:+ v${TOOL_VERSION}}"
    return 0
  fi
  "$install_func"
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_init installer_show_help installer_parse_args
export -f installer_check_version installer_download_binary
export -f installer_fallback_go installer_fallback_brew installer_fallback_cargo
export -f installer_run_chain installer_run
