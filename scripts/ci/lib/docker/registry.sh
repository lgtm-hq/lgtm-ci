#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Docker registry authentication utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
#   docker_login_ghcr "$GITHUB_TOKEN"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_DOCKER_REGISTRY_LOADED:-}" ]] && return 0
readonly _LGTM_CI_DOCKER_REGISTRY_LOADED=1

# Login to GitHub Container Registry (ghcr.io)
# Usage: docker_login_ghcr token [username]
# Args:
#   token - GitHub token with packages:write permission
#   username - Optional username (defaults to GITHUB_ACTOR or git config)
docker_login_ghcr() {
	local token="${1:-}"
	local username="${2:-}"

	if [[ -z "$token" ]]; then
		echo "Error: GitHub token required for GHCR login" >&2
		return 1
	fi

	# Determine username
	if [[ -z "$username" ]]; then
		username="${GITHUB_ACTOR:-}"
	fi
	if [[ -z "$username" ]]; then
		username=$(git config user.name 2>/dev/null || echo "")
	fi
	if [[ -z "$username" ]]; then
		echo "Error: Could not determine username for GHCR login" >&2
		return 1
	fi

	echo "$token" | docker login ghcr.io -u "$username" --password-stdin
}

# Login to Docker Hub
# Usage: docker_login_dockerhub username token
docker_login_dockerhub() {
	local username="${1:-}"
	local token="${2:-}"

	if [[ -z "$username" ]] || [[ -z "$token" ]]; then
		echo "Error: Username and token required for Docker Hub login" >&2
		return 1
	fi

	echo "$token" | docker login -u "$username" --password-stdin
}

# Login to a generic registry
# Usage: docker_login_generic registry username password
docker_login_generic() {
	local registry="${1:-}"
	local username="${2:-}"
	local password="${3:-}"

	if [[ -z "$registry" ]] || [[ -z "$username" ]] || [[ -z "$password" ]]; then
		echo "Error: Registry, username, and password required" >&2
		return 1
	fi

	echo "$password" | docker login "$registry" -u "$username" --password-stdin
}

# Get registry URL from image name
# Usage: get_registry_url image_name
# Returns: registry URL or "docker.io" for Docker Hub
get_registry_url() {
	local image="${1:-}"

	# Check for explicit registry prefix
	if [[ "$image" == *"/"* ]]; then
		local first_part="${image%%/*}"
		# If first part contains a dot or colon, it's a registry
		if [[ "$first_part" == *"."* ]] || [[ "$first_part" == *":"* ]]; then
			echo "$first_part"
			return 0
		fi
	fi

	# Default to Docker Hub
	echo "docker.io"
}

# Normalize registry URL for consistency
# Usage: normalize_registry_url registry
normalize_registry_url() {
	local registry="${1:-}"

	# Remove trailing slashes
	registry="${registry%/}"

	# Normalize Docker Hub variants
	case "$registry" in
	"docker.io" | "index.docker.io" | "registry-1.docker.io" | "")
		echo "docker.io"
		;;
	*)
		echo "$registry"
		;;
	esac
}

# Check if logged into a registry
# Usage: check_registry_auth registry
# Returns: 0 if authenticated, 1 if not
check_registry_auth() {
	local registry="${1:-docker.io}"

	registry=$(normalize_registry_url "$registry")

	# Check Docker config for auth
	local config_file="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
	if [[ -f "$config_file" ]]; then
		if jq -e ".auths.\"$registry\" // .auths.\"https://$registry\"" "$config_file" &>/dev/null; then
			return 0
		fi
	fi

	return 1
}

# Export functions
export -f docker_login_ghcr docker_login_dockerhub docker_login_generic
export -f get_registry_url normalize_registry_url check_registry_auth
