#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Persist a build-push-action digest to a file (build-docker STEP: record-digest)
#
# Required environment variables:
#   DIGEST      - Image digest emitted by build-push-action (sha256:...)
#   DIGEST_FILE - Absolute path to write the digest to

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${DIGEST:?DIGEST is required}"
: "${DIGEST_FILE:?DIGEST_FILE is required}"

if ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
	die "DIGEST is not a valid sha256 digest: ${DIGEST}"
fi

mkdir -p "$(dirname "$DIGEST_FILE")"
printf '%s' "$DIGEST" >"$DIGEST_FILE"
log_info "Recorded digest to ${DIGEST_FILE}"
