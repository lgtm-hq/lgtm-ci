#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Push built image tags to the registry (build-docker STEP: push)
#
# Optional environment variables:
#   REGISTRY - Registry URL (default: ghcr.io)
#   IMAGE_NAME - Image name (default: from GITHUB_REPOSITORY)
#   TAGS - Tags to push (newline- or comma-separated)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${REGISTRY:=ghcr.io}"
: "${IMAGE_NAME:=${GITHUB_REPOSITORY:-}}"
: "${TAGS:=}"

log_info "Pushing image tags..."

# Parse tags (handle both newline and comma-separated formats)
while IFS= read -r tag; do
	tag=$(echo "$tag" | xargs) # Trim whitespace
	if [[ -n "$tag" ]]; then
		log_info "Pushing: $tag"
		docker push "$tag"
	fi
done < <(printf '%s\n' "$TAGS" | tr ',' '\n')

log_success "Push completed"
