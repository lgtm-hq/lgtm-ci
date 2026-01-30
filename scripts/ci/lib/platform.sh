#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Platform detection utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"
#   platform=$(detect_platform)

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_PLATFORM_LOADED:-}" ]] && return 0
readonly _LGTM_CI_PLATFORM_LOADED=1

# =============================================================================
# Platform detection
# =============================================================================

# Detect OS name (lowercase)
# Returns: linux, darwin, windows
detect_os() {
	local os
	os=$(uname -s | tr '[:upper:]' '[:lower:]')
	case "$os" in
	mingw* | msys* | cygwin*) os="windows" ;;
	esac
	echo "$os"
}

# Detect architecture (normalized)
# Returns: x86_64, arm64, or x86
detect_arch() {
	local arch
	arch=$(uname -m)
	case "$arch" in
	x86_64 | amd64) arch="x86_64" ;;
	aarch64 | arm64) arch="arm64" ;;
	i386 | i686) arch="x86" ;;
	esac
	echo "$arch"
}

# Detect platform and architecture combined
# Returns: os-arch (e.g., "linux-x86_64", "darwin-arm64")
detect_platform() {
	echo "$(detect_os)-$(detect_arch)"
}

# Check if running on macOS
is_macos() {
	[[ "$(detect_os)" == "darwin" ]]
}

# Check if running on Linux
is_linux() {
	[[ "$(detect_os)" == "linux" ]]
}

# Check if running on Windows (Git Bash, WSL, etc.)
is_windows() {
	[[ "$(detect_os)" == "windows" ]]
}

# Check if running on ARM architecture
is_arm() {
	[[ "$(detect_arch)" == "arm64" ]]
}

# =============================================================================
# Export functions
# =============================================================================
export -f detect_os detect_arch detect_platform
export -f is_macos is_linux is_windows is_arm
