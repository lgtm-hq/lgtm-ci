#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify Docker and Buildx availability (build-docker STEP: setup)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

log_info "Setting up Docker environment..."

# Check Docker availability
if ! check_docker_available; then
	die "Docker is not available or not running"
fi

# Check Buildx availability
if ! check_buildx_available; then
	die "Docker Buildx is not available"
fi

log_info "Docker version: $(docker --version)"
log_info "Buildx version: $(docker buildx version)"

log_success "Docker environment ready"
