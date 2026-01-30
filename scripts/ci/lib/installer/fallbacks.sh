#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fallback installation methods (go, brew, cargo)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/fallbacks.sh"
#   installer_fallback_brew "formula"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_FALLBACKS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_INSTALLER_FALLBACKS_LOADED=1

# Fallbacks
command_exists() { command -v "$1" >/dev/null 2>&1; }
log_verbose() { [[ "${VERBOSE:-0}" -eq 1 ]] && echo "[VERBOSE] $*" >&2 || true; }
log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_success() { echo "[SUCCESS] $*" >&2; }

# =============================================================================
# Fallback installers
# =============================================================================

# Try go install as fallback
# Usage: installer_fallback_go "github.com/user/repo/cmd/tool@version"
installer_fallback_go() {
  local package="$1"

  if ! command_exists go; then
    log_verbose "go not available for fallback"
    return 1
  fi

  log_info "Trying go install..."
  if go install "$package" 2>/dev/null; then
    log_success "${TOOL_NAME:-tool} installed via go install"
    return 0
  fi
  return 1
}

# Try brew install as fallback
# Usage: installer_fallback_brew "formula" [--cask]
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
    log_success "${TOOL_NAME:-tool} installed via Homebrew"
    return 0
  fi
  return 1
}

# Try rustup/cargo as fallback
# Usage: installer_fallback_cargo "package@version"
installer_fallback_cargo() {
  local package="$1"

  if ! command_exists cargo; then
    log_verbose "cargo not available for fallback"
    return 1
  fi

  log_info "Trying cargo install..."
  if cargo install "$package" 2>/dev/null; then
    log_success "${TOOL_NAME:-tool} installed via cargo"
    return 0
  fi
  return 1
}

# =============================================================================
# Installation chain execution
# =============================================================================

# Run a chain of installation methods until one succeeds
# Usage: installer_run_chain "method1" "method2" "method3" ...
installer_run_chain() {
  local method
  for method in "$@"; do
    if eval "$method"; then
      return 0
    fi
  done

  echo "[ERROR] Failed to install ${TOOL_NAME:-tool}" >&2
  return 1
}

# Wrap installation function with dry-run check
# Usage: installer_run install_function
installer_run() {
  local install_func="$1"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "[DRY-RUN] Would install ${TOOL_NAME:-tool}${TOOL_VERSION:+ v${TOOL_VERSION}}"
    return 0
  fi

  "$install_func"
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_fallback_go installer_fallback_brew installer_fallback_cargo
export -f installer_run_chain installer_run
