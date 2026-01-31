#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Docker utilities library aggregator
#
# Sources all Docker-related libraries for convenient single-file import.
# Usage: source "scripts/ci/lib/docker.sh"

# Guard against multiple sourcing
[[ -n "${_LGTM_CI_DOCKER_LOADED:-}" ]] && return 0
readonly _LGTM_CI_DOCKER_LOADED=1

# Get the directory of this script
DOCKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all docker sub-libraries in dependency order
# shellcheck source=./docker/core.sh
source "$DOCKER_LIB_DIR/docker/core.sh"

# shellcheck source=./docker/registry.sh
source "$DOCKER_LIB_DIR/docker/registry.sh"

# shellcheck source=./docker/tags.sh
source "$DOCKER_LIB_DIR/docker/tags.sh"
