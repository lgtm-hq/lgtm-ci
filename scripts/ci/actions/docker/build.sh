#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build a Docker image with buildx (build-docker STEP: build)
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
#                Note: Values containing commas are not supported
#   LABELS - Additional labels (comma-separated key=value)
#            Note: Values containing commas are not supported
#   CACHE_FROM - Cache sources
#   CACHE_TO - Cache destinations
#   BUILD_LOG - File to tee the buildx output to, so a later failure step can
#               scan it for blocked-egress signatures
#               (default: $RUNNER_TEMP/docker-build.log)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

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
: "${BUILD_LOG:=${RUNNER_TEMP:-/tmp}/docker-build.log}"

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

# Add platforms (--load only supports single-platform builds)
if [[ "$LOAD" != "true" ]]; then
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

# Log command without sensitive args (build-args and labels may contain secrets)
safe_cmd=()
skip_next=0
for arg in "${BUILD_CMD[@]}"; do
	if [[ "$skip_next" -eq 1 ]]; then
		# Skip the secret value following --build-arg or --label
		skip_next=0
		continue
	elif [[ "$arg" == "--build-arg" ]] || [[ "$arg" == "--label" ]]; then
		safe_cmd+=("$arg" "[REDACTED]")
		skip_next=1
	else
		safe_cmd+=("$arg")
	fi
done
log_info "Running: ${safe_cmd[*]}"

# Execute build, teeing output to BUILD_LOG so a failure step can scan it
# for blocked-egress signatures. The log is best-effort diagnostics: take the
# build's own exit code from PIPESTATUS[0] (not the pipeline status) so a tee
# failure (e.g. unwritable BUILD_LOG) can never misreport the build result.
mkdir -p "$(dirname "$BUILD_LOG")" 2>/dev/null || true
set +e
"${BUILD_CMD[@]}" 2>&1 | tee "$BUILD_LOG"
exit_code=${PIPESTATUS[0]}
set -e

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
