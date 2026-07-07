#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a detached-container health check against a locally loaded image
#          (build-docker STEP: health-check-local)
#
# Required environment variables:
#   IMAGE              - Full local image reference (registry/name:tag)
#   HEALTH_CHECK_CMD   - Command executed on the runner (requires port)
#   HEALTH_CHECK_PORT  - Port published on 127.0.0.1 for the command
#
# Optional environment variables:
#   PLATFORM              - Target platform (e.g. linux/arm64)
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

: "${IMAGE:?IMAGE is required}"
: "${HEALTH_CHECK_CMD:?HEALTH_CHECK_CMD is required}"
: "${HEALTH_CHECK_PORT:?HEALTH_CHECK_PORT is required}"
: "${PLATFORM:=}"
: "${HEALTH_CHECK_TIMEOUT:=30s}"

export IMAGE PLATFORM HEALTH_CHECK_CMD HEALTH_CHECK_PORT HEALTH_CHECK_TIMEOUT
run_health_check
