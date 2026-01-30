#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Configure common CI environment variables and PATH
#
# Required environment variables:
#   BIN_DIR - Directory for installed binaries
#   ADD_TO_PATH - Additional directories to add to PATH (comma-separated)

set -euo pipefail

: "${BIN_DIR:?BIN_DIR is required}"
: "${ADD_TO_PATH:=}"

# Detect platform
detect_platform() {
	local os arch
	os=$(uname -s | tr '[:upper:]' '[:lower:]')
	case "$os" in
	mingw* | msys* | cygwin*) os="windows" ;;
	esac

	arch=$(uname -m)
	case "$arch" in
	x86_64 | amd64) arch="x86_64" ;;
	aarch64 | arm64) arch="arm64" ;;
	i386 | i686) arch="x86" ;;
	esac

	{
		echo "os=$os"
		echo "arch=$arch"
		echo "platform=${os}-${arch}"
	} >>"$GITHUB_OUTPUT"
	echo "Detected platform: ${os}-${arch}"
}

# Setup bin directory
setup_bin_dir() {
	mkdir -p "$BIN_DIR"
	echo "$BIN_DIR" >>"$GITHUB_PATH"
	echo "BIN_DIR=$BIN_DIR" >>"$GITHUB_ENV"
	echo "Added $BIN_DIR to PATH"
}

# Add extra paths
add_extra_paths() {
	if [[ -n "$ADD_TO_PATH" ]]; then
		IFS=',' read -ra PATHS <<<"$ADD_TO_PATH"
		for path in "${PATHS[@]}"; do
			path=$(echo "$path" | xargs) # trim whitespace
			if [[ -n "$path" ]]; then
				mkdir -p "$path"
				echo "$path" >>"$GITHUB_PATH"
				echo "Added $path to PATH"
			fi
		done
	fi
}

# Set common environment variables
set_common_env() {
	{
		# Disable interactive prompts
		echo "CI=true"
		echo "NONINTERACTIVE=1"

		# Disable telemetry for common tools
		echo "DO_NOT_TRACK=1"
		echo "HOMEBREW_NO_ANALYTICS=1"
		echo "DOTNET_CLI_TELEMETRY_OPTOUT=1"
		echo "NEXT_TELEMETRY_DISABLED=1"
	} >>"$GITHUB_ENV"
}

# Main
detect_platform
setup_bin_dir
add_extra_paths
set_common_env
