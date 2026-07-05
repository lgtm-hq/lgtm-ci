#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the first metadata tag for scanning a locally loaded image
#          (build-docker STEP: resolve-local-scan-image)
#
# Required environment variables:
#   TAGS - Newline-separated image tags from docker/metadata-action
#
# Outputs:
#   ref - First tag suitable for Trivy image-ref

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
	die "No image tag available for local Trivy scan"
fi

set_github_output "ref" "$first_tag"
log_info "Local scan image: ${first_tag}"
