#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Sign a pushed image manifest with Cosign keyless signing
#          (build-docker STEP: sign-image)
#
# Required environment variables:
#   DIGEST     - Image digest (sha256:...)
#   REGISTRY   - Container registry URL
#   IMAGE_NAME - Registry-relative image name
#
# Optional environment variables (see scripts/ci/lib/cosign.sh):
#   COSIGN_SIGN_MAX_ATTEMPTS - Max signing attempts (default: 3, minimum 1)
#   COSIGN_SIGN_MAX_DELAY    - Cap for the exponential backoff, seconds
#                              (default: 30)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"
# shellcheck source=../../lib/cosign.sh
source "$SCRIPT_DIR/../../lib/cosign.sh"

: "${DIGEST:?DIGEST is required}"
: "${REGISTRY:?REGISTRY is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"

if ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
	die "DIGEST is not a valid sha256 digest: ${DIGEST}"
fi

cosign_validate_retry_bounds

if ! command -v cosign >/dev/null 2>&1; then
	die "cosign not found. Install via sigstore/cosign-installer action."
fi

image_ref="${REGISTRY}/${IMAGE_NAME}@${DIGEST}"
log_info "Signing image: ${image_ref}"
cosign_sign_with_retry "cosign sign" "$image_ref" \
	cosign sign --yes "$image_ref"
log_success "Signed image: ${image_ref}"
