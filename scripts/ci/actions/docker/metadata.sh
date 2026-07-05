#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Extract the image digest from a built tag (build-docker STEP: metadata)
#
# Optional environment variables:
#   REGISTRY - Registry URL (default: ghcr.io)
#   IMAGE_NAME - Image name (default: from GITHUB_REPOSITORY)
#   BUILT_TAGS - Newline-separated tags produced by the build step
#
# Outputs:
#   digest - Manifest digest of the first built tag (empty when unavailable)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

# Extract digest from a built image using a concrete tag
: "${REGISTRY:=ghcr.io}"
: "${IMAGE_NAME:=${GITHUB_REPOSITORY:-}}"
: "${BUILT_TAGS:=}"

log_info "Extracting image metadata..."

# Parse first tag from newline-separated list
first_tag=$(echo "$BUILT_TAGS" | head -1)
fmt='{{.Manifest.Digest}}'

if [[ -n "$first_tag" ]]; then
	log_info "Using tag: $first_tag"
	digest=$(docker buildx imagetools inspect "$first_tag" --format "$fmt" 2>/dev/null || echo "")
else
	# Fallback to image:latest if no tags available
	full_image="${REGISTRY}/${IMAGE_NAME}:latest"
	log_info "No tags found, falling back to: $full_image"
	digest=$(docker buildx imagetools inspect "$full_image" --format "$fmt" 2>/dev/null || echo "")
fi

set_github_output "digest" "$digest"

if [[ -n "$digest" ]]; then
	log_success "Extracted digest: $digest"
else
	log_warn "Could not extract digest"
fi
