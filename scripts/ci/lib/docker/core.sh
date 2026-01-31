#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Docker core utilities - buildx setup and platform detection
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
#   setup_buildx_builder

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_DOCKER_CORE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_DOCKER_CORE_LOADED=1

# Check if Docker is available
# Returns: 0 if available, 1 if not
check_docker_available() {
	if ! command -v docker &>/dev/null; then
		return 1
	fi

	# Verify Docker daemon is running
	if ! docker info &>/dev/null; then
		return 1
	fi

	return 0
}

# Check if Docker Buildx is available
# Returns: 0 if available, 1 if not
check_buildx_available() {
	if ! docker buildx version &>/dev/null; then
		return 1
	fi
	return 0
}

# Setup Docker Buildx builder for multi-platform builds
# Usage: setup_buildx_builder [builder_name]
# Sets: DOCKER_BUILDER_NAME
setup_buildx_builder() {
	local builder_name="${1:-lgtm-builder}"

	# Check if builder exists
	if docker buildx inspect "$builder_name" &>/dev/null; then
		docker buildx use "$builder_name"
		DOCKER_BUILDER_NAME="$builder_name"
		return 0
	fi

	# Create new builder with docker-container driver for multi-platform
	docker buildx create \
		--name "$builder_name" \
		--driver docker-container \
		--bootstrap \
		--use

	DOCKER_BUILDER_NAME="$builder_name"
	return 0
}

# Get default platforms for multi-platform builds
# Returns: comma-separated platform list
get_default_platforms() {
	echo "linux/amd64,linux/arm64"
}

# Get current platform in Docker format
# Returns: platform string (e.g., linux/amd64)
get_current_platform() {
	local os arch

	os=$(uname -s | tr '[:upper:]' '[:lower:]')
	arch=$(uname -m)

	# Normalize architecture names
	case "$arch" in
	x86_64 | amd64)
		arch="amd64"
		;;
	aarch64 | arm64)
		arch="arm64"
		;;
	armv7l)
		arch="arm/v7"
		;;
	esac

	echo "${os}/${arch}"
}

# Check if QEMU is needed for cross-platform builds
# Args: platforms (comma-separated)
# Returns: 0 if QEMU needed, 1 if not
needs_qemu() {
	local platforms="${1:-}"
	local current_platform

	current_platform=$(get_current_platform)

	# Check if any requested platform differs from current
	IFS=',' read -ra platform_array <<<"$platforms"
	for platform in "${platform_array[@]}"; do
		if [[ "$platform" != "$current_platform" ]]; then
			return 0
		fi
	done

	return 1
}

# Export functions
export -f check_docker_available check_buildx_available setup_buildx_builder
export -f get_default_platforms get_current_platform needs_qemu
