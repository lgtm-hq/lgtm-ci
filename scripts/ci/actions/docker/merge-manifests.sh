#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Assemble a multi-arch manifest list from per-platform staging images
#          (build-docker STEP: merge-manifests)
#
# Required environment variables:
#   MATRIX     - JSON matrix from classify step (array of {platform, runner, slug, qemu})
#   REGISTRY   - Container registry URL
#   IMAGE_NAME - Registry-relative image name
#   RUN_ID     - GitHub Actions run ID used to locate staging tags
#   TARGET_TAGS - Newline-separated list of final tags to create

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${MATRIX:?MATRIX is required}"
: "${REGISTRY:?REGISTRY is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${RUN_ID:?RUN_ID is required}"
: "${TARGET_TAGS:?TARGET_TAGS is required}"

MERGE_CMD=("docker" "buildx" "imagetools" "create")

while IFS= read -r tag; do
	tag=$(echo "$tag" | xargs)
	[[ -n "$tag" ]] && MERGE_CMD+=("--tag" "$tag")
done <<<"$TARGET_TAGS"

# Validate at least one --tag was appended (TARGET_TAGS was not all whitespace)
if [[ "${#MERGE_CMD[@]}" -le 4 ]]; then
	log_error "No valid tags found in TARGET_TAGS — cannot create manifest"
	exit 1
fi

# Add per-platform staging images as sources (referenced by staging tag)
while IFS= read -r slug; do
	[[ -n "$slug" ]] && MERGE_CMD+=("${REGISTRY}/${IMAGE_NAME}:build-${RUN_ID}-${slug}")
done < <(echo "$MATRIX" | jq -r '.[].slug')

platform_count=$(echo "$MATRIX" | jq 'length')
log_info "Merging ${platform_count} platform(s) into manifest..."
"${MERGE_CMD[@]}"
log_success "Multi-arch manifest created"
