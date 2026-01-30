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

# Source shared libraries
_LGTM_CI_FALLBACKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source logging and fs utilities (with fallbacks for standalone use)
if [[ -f "$_LGTM_CI_FALLBACKS_LIB_DIR/log.sh" ]]; then
	# shellcheck source=../log.sh
	source "$_LGTM_CI_FALLBACKS_LIB_DIR/log.sh"
else
	log_verbose() { [[ "${VERBOSE:-}" == "1" ]] && echo "[VERBOSE] $*" >&2 || true; }
	log_info() { echo "[INFO] $*" >&2; }
	log_warn() { echo "[WARN] $*" >&2; }
	log_success() { echo "[SUCCESS] $*" >&2; }
	export -f log_verbose log_info log_warn log_success
fi

if [[ -f "$_LGTM_CI_FALLBACKS_LIB_DIR/fs.sh" ]]; then
	# shellcheck source=../fs.sh
	source "$_LGTM_CI_FALLBACKS_LIB_DIR/fs.sh"
elif ! declare -f command_exists &>/dev/null; then
	command_exists() { command -v "$1" >/dev/null 2>&1; }
	export -f command_exists
fi

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
	local status output
	if [[ "${VERBOSE:-}" == "1" ]]; then
		go install "$package"
		status=$?
	else
		# Capture stderr to show on failure
		output=$(go install "$package" 2>&1) || true
		status=$?
		if [[ $status -ne 0 ]]; then
			echo "$output" >&2
		fi
	fi

	if [[ $status -eq 0 ]]; then
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

	local status output
	if [[ "${VERBOSE:-}" == "1" ]]; then
		brew "${brew_args[@]}"
		status=$?
	else
		# Capture stderr to show on failure
		output=$(brew "${brew_args[@]}" 2>&1) || true
		status=$?
		if [[ $status -ne 0 ]]; then
			echo "$output" >&2
		fi
	fi

	if [[ $status -eq 0 ]]; then
		log_success "${TOOL_NAME:-tool} installed via Homebrew"
		return 0
	fi
	return 1
}

# Try rustup/cargo as fallback
# Usage: installer_fallback_cargo "package" or "package@version"
# Supports both "ripgrep" and "ripgrep@14.0.0" formats
installer_fallback_cargo() {
	local package="$1"
	local cargo_args=("install")

	if ! command_exists cargo; then
		log_verbose "cargo not available for fallback"
		return 1
	fi

	# Handle package@version format (cargo uses --version flag)
	if [[ "$package" == *"@"* ]]; then
		local name="${package%%@*}"
		local version="${package#*@}"
		cargo_args+=("$name" "--version" "$version")
	else
		cargo_args+=("$package")
	fi

	log_info "Trying cargo install..."
	local status output
	if [[ "${VERBOSE:-}" == "1" ]]; then
		cargo "${cargo_args[@]}"
		status=$?
	else
		# Capture stderr to show on failure
		output=$(cargo "${cargo_args[@]}" 2>&1) || true
		status=$?
		if [[ $status -ne 0 ]]; then
			echo "$output" >&2
		fi
	fi

	if [[ $status -eq 0 ]]; then
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
# Note: Methods should be function names (not commands with args) to avoid eval
installer_run_chain() {
	local method
	for method in "$@"; do
		# Direct function invocation instead of eval for safety
		if "$method"; then
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

	# String comparison to handle "1", "true", "yes" values
	local dry_run="${DRY_RUN:-0}"
	dry_run="${dry_run,,}" # lowercase
	if [[ "$dry_run" == "1" || "$dry_run" == "true" || "$dry_run" == "yes" ]]; then
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
