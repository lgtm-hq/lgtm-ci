#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the first metadata tag for a locally loaded health-check image
#          (build-docker STEP: resolve-local-health-check-image)
#
# Required environment variables:
#   TAGS - Newline-separated image tags from docker/metadata-action
#
# Outputs:
#   image - First tag suitable for detached-container health checks

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${TAGS:?TAGS is required}"

first_tag=$(echo "$TAGS" | head -1 | tr -d '[:space:]')
if [[ -z "$first_tag" ]]; then
	die "No image tag available for local health check"
fi

set_github_output "image" "$first_tag"
log_info "Local health-check image: ${first_tag}"
