#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write a pre-computed digest to GITHUB_OUTPUT (build-docker STEP: set-output-digest)
#
# Required environment variables:
#   DIGEST - Image digest (e.g. sha256:abc123...)
#
# Outputs:
#   digest - The provided digest

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${DIGEST:?DIGEST is required}"
set_github_output "digest" "${DIGEST}"
log_info "Digest: ${DIGEST}"
