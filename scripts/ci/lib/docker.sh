#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Docker utilities library aggregator
#
# Sources all Docker-related libraries for convenient single-file import.
# Usage: source "scripts/ci/lib/docker.sh"
#
# Loading contract: all docker/* modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Guard against multiple sourcing
[[ -n "${_LGTM_CI_DOCKER_LOADED:-}" ]] && return 0

# Get the directory of this script
DOCKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)" || {
	echo "docker.sh: cannot resolve library directory" >&2
	return 1
}

# Source all docker sub-libraries in dependency order (all required)
[[ -f "$DOCKER_LIB_DIR/docker/core.sh" ]] || {
	echo "docker.sh: missing required module docker/core.sh in $DOCKER_LIB_DIR" >&2
	return 1
}
# shellcheck source=./docker/core.sh
source "$DOCKER_LIB_DIR/docker/core.sh" || return 1

[[ -f "$DOCKER_LIB_DIR/docker/registry.sh" ]] || {
	echo "docker.sh: missing required module docker/registry.sh in $DOCKER_LIB_DIR" >&2
	return 1
}
# shellcheck source=./docker/registry.sh
source "$DOCKER_LIB_DIR/docker/registry.sh" || return 1

[[ -f "$DOCKER_LIB_DIR/docker/tags.sh" ]] || {
	echo "docker.sh: missing required module docker/tags.sh in $DOCKER_LIB_DIR" >&2
	return 1
}
# shellcheck source=./docker/tags.sh
source "$DOCKER_LIB_DIR/docker/tags.sh" || return 1

readonly _LGTM_CI_DOCKER_LOADED=1
