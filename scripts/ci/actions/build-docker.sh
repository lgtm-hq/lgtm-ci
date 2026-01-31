#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build and push Docker images with multi-platform support
#
# Required environment variables:
#   STEP - Which step to run: setup, build, push, summary
#
# Optional environment variables:
#   CONTEXT - Build context path (default: .)
#   FILE - Dockerfile path (default: Dockerfile)
#   PLATFORMS - Target platforms (default: linux/amd64,linux/arm64)
#   REGISTRY - Registry URL (default: ghcr.io)
#   IMAGE_NAME - Image name (default: from GITHUB_REPOSITORY)
#   TAGS - Additional tags (comma-separated)
#   VERSION - Version for semver tags
#   PUSH - Push to registry (default: false)
#   LOAD - Load into local docker (default: false)
#   BUILD_ARGS - Build arguments (comma-separated key=value)
#   LABELS - Additional labels (comma-separated key=value)
#   CACHE_FROM - Cache sources
#   CACHE_TO - Cache destinations

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/docker.sh
source "$SCRIPT_DIR/../lib/docker.sh"

case "$STEP" in
setup)
	log_info "Setting up Docker environment..."

	# Check Docker availability
	if ! check_docker_available; then
		die "Docker is not available or not running"
	fi

	# Check Buildx availability
	if ! check_buildx_available; then
		die "Docker Buildx is not available"
	fi

	log_info "Docker version: $(docker --version)"
	log_info "Buildx version: $(docker buildx version)"

	log_success "Docker environment ready"
	;;

build)
	: "${CONTEXT:=.}"
	: "${FILE:=Dockerfile}"
	: "${PLATFORMS:=linux/amd64,linux/arm64}"
	: "${REGISTRY:=ghcr.io}"
	: "${IMAGE_NAME:=${GITHUB_REPOSITORY:-}}"
	: "${TAGS:=}"
	: "${VERSION:=}"
	: "${PUSH:=false}"
	: "${LOAD:=false}"
	: "${BUILD_ARGS:=}"
	: "${LABELS:=}"
	: "${CACHE_FROM:=}"
	: "${CACHE_TO:=}"

	# Validate required inputs
	if [[ -z "$IMAGE_NAME" ]]; then
		die "IMAGE_NAME is required (or set GITHUB_REPOSITORY)"
	fi

	# Construct full image name
	full_image="${REGISTRY}/${IMAGE_NAME}"

	log_info "Building image: $full_image"
	log_info "Context: $CONTEXT"
	log_info "Dockerfile: $FILE"
	log_info "Platforms: $PLATFORMS"

	# Build docker buildx command
	BUILD_CMD=("docker" "buildx" "build")
	BUILD_CMD+=("--file" "$FILE")

	# Add platforms (only for push, not for load)
	if [[ "$PUSH" == "true" ]] || [[ "$LOAD" == "false" ]]; then
		BUILD_CMD+=("--platform" "$PLATFORMS")
	fi

	# Generate and add tags
	all_tags=()

	# Add SHA tag
	sha_tag=$(generate_sha_tag 2>/dev/null || echo "")
	if [[ -n "$sha_tag" ]]; then
		all_tags+=("${full_image}:${sha_tag}")
	fi

	# Add version tags if provided
	if [[ -n "$VERSION" ]]; then
		while IFS= read -r tag; do
			all_tags+=("${full_image}:${tag}")
		done < <(generate_semver_tags "$VERSION" 2>/dev/null || true)
	fi

	# Add branch tag
	branch_tag=$(generate_branch_tag 2>/dev/null || echo "")
	if [[ -n "$branch_tag" ]]; then
		all_tags+=("${full_image}:${branch_tag}")
	fi

	# Add custom tags
	if [[ -n "$TAGS" ]]; then
		IFS=',' read -ra custom_tags <<<"$TAGS"
		for tag in "${custom_tags[@]}"; do
			tag=$(echo "$tag" | xargs) # Trim whitespace
			if [[ -n "$tag" ]]; then
				# Add registry prefix if not present
				if [[ "$tag" != *":"* ]]; then
					all_tags+=("${full_image}:${tag}")
				else
					all_tags+=("$tag")
				fi
			fi
		done
	fi

	# Add tags to command
	for tag in "${all_tags[@]}"; do
		BUILD_CMD+=("--tag" "$tag")
	done

	# Add build args
	if [[ -n "$BUILD_ARGS" ]]; then
		IFS=',' read -ra args <<<"$BUILD_ARGS"
		for arg in "${args[@]}"; do
			BUILD_CMD+=("--build-arg" "$arg")
		done
	fi

	# Add labels
	if [[ -n "$LABELS" ]]; then
		IFS=',' read -ra label_args <<<"$LABELS"
		for label in "${label_args[@]}"; do
			BUILD_CMD+=("--label" "$label")
		done
	fi

	# Add OCI labels
	BUILD_CMD+=("--label" "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-unknown}")
	BUILD_CMD+=("--label" "org.opencontainers.image.revision=${GITHUB_SHA:-unknown}")
	BUILD_CMD+=("--label" "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)")

	# Add cache configuration
	if [[ -n "$CACHE_FROM" ]]; then
		BUILD_CMD+=("--cache-from" "$CACHE_FROM")
	fi
	if [[ -n "$CACHE_TO" ]]; then
		BUILD_CMD+=("--cache-to" "$CACHE_TO")
	fi

	# Add push/load flags
	if [[ "$PUSH" == "true" ]]; then
		BUILD_CMD+=("--push")
	elif [[ "$LOAD" == "true" ]]; then
		BUILD_CMD+=("--load")
	fi

	# Add context
	BUILD_CMD+=("$CONTEXT")

	log_info "Running: ${BUILD_CMD[*]}"

	# Execute build
	exit_code=0
	"${BUILD_CMD[@]}" || exit_code=$?

	# Set outputs
	set_github_output "exit-code" "$exit_code"

	# Output tags as newline-separated list
	tags_output=$(printf '%s\n' "${all_tags[@]}")
	set_github_output_multiline "tags" "$tags_output"

	if [[ $exit_code -eq 0 ]]; then
		log_success "Build completed successfully"
	else
		log_error "Build failed with exit code: $exit_code"
	fi

	exit "$exit_code"
	;;

push)
	: "${REGISTRY:=ghcr.io}"
	: "${IMAGE_NAME:=${GITHUB_REPOSITORY:-}}"
	: "${TAGS:=}"

	log_info "Pushing image tags..."

	# Parse tags and push each
	IFS=',' read -ra tag_array <<<"$TAGS"
	for tag in "${tag_array[@]}"; do
		tag=$(echo "$tag" | xargs)
		if [[ -n "$tag" ]]; then
			log_info "Pushing: $tag"
			docker push "$tag"
		fi
	done

	log_success "Push completed"
	;;

summary)
	: "${IMAGE_NAME:=}"
	: "${TAGS:=}"
	: "${PLATFORMS:=}"
	: "${PUSH:=false}"

	add_github_summary "## Docker Build Results"
	add_github_summary ""

	add_github_summary "| Property | Value |"
	add_github_summary "|----------|-------|"
	add_github_summary "| Image | \`$IMAGE_NAME\` |"
	add_github_summary "| Platforms | \`$PLATFORMS\` |"
	add_github_summary "| Pushed | $PUSH |"
	add_github_summary ""

	if [[ -n "$TAGS" ]]; then
		add_github_summary "### Tags"
		add_github_summary ""
		# TAGS is newline-separated, read into array properly
		readarray -t tag_array <<<"$TAGS"
		for tag in "${tag_array[@]}"; do
			# Trim whitespace
			tag=$(echo "$tag" | xargs)
			if [[ -n "$tag" ]]; then
				add_github_summary "- \`$tag\`"
			fi
		done
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
