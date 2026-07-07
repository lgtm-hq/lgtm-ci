#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a detached-container health check against a staging image by digest
#          (build-docker STEP: health-check)
#
# Required environment variables:
#   REGISTRY           - Container registry URL
#   IMAGE_NAME         - Registry-relative image name
#   PLATFORM           - Target platform (e.g. linux/arm64)
#   DIGEST_FILE        - Path to sha256 digest for the staging image
#   HEALTH_CHECK_CMD   - Command executed on the runner (requires port)
#   HEALTH_CHECK_PORT  - Port published on 127.0.0.1 for the command
#
# Optional environment variables:
#   HEALTH_CHECK_TIMEOUT  - Max wait time (default: 30s)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"
# shellcheck source=health-lib.sh
source "$SCRIPT_DIR/health-lib.sh"

: "${REGISTRY:?REGISTRY is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${PLATFORM:?PLATFORM is required}"
: "${DIGEST_FILE:?DIGEST_FILE is required}"
: "${HEALTH_CHECK_CMD:?HEALTH_CHECK_CMD is required}"
: "${HEALTH_CHECK_PORT:?HEALTH_CHECK_PORT is required}"
: "${HEALTH_CHECK_TIMEOUT:=30s}"

if [[ ! -s "$DIGEST_FILE" ]]; then
	die "DIGEST_FILE missing or empty: ${DIGEST_FILE}"
fi

digest=$(<"$DIGEST_FILE")
if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
	die "Invalid digest in ${DIGEST_FILE}: ${digest}"
fi

IMAGE="${REGISTRY}/${IMAGE_NAME}@${digest}"
export IMAGE PLATFORM HEALTH_CHECK_CMD HEALTH_CHECK_PORT HEALTH_CHECK_TIMEOUT

echo "::group::Pulling ${IMAGE} (${PLATFORM})"
docker pull --platform "${PLATFORM}" "${IMAGE}"
echo "::endgroup::"

run_health_check
