#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Docker registry login helpers
#
# Required environment variables:
#   STEP - Which step to run: validate
#
# validate step environment variables:
#   REGISTRY        - Container registry URL (required)
#   DOCKERHUB_USERNAME - Docker Hub username (required when REGISTRY=docker.io)
#   DOCKERHUB_TOKEN    - Docker Hub token (required when REGISTRY=docker.io)

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
validate)
	: "${REGISTRY:?REGISTRY is required}"

	if [[ "${REGISTRY}" != "ghcr.io" && "${REGISTRY}" != "docker.io" ]]; then
		die "Unsupported registry '${REGISTRY}'. Supported values: ghcr.io, docker.io"
	fi

	if [[ "${REGISTRY}" == "docker.io" ]]; then
		if [[ -z "${DOCKERHUB_USERNAME:-}" || -z "${DOCKERHUB_TOKEN:-}" ]]; then
			die "DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are required when REGISTRY is docker.io"
		fi
	fi

	log_success "Registry validation passed: ${REGISTRY}"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
