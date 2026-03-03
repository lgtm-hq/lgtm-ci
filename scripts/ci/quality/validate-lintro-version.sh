#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate that the lintro Docker image version matches pyproject.toml
#
# Ensures version consistency between the lintro container used in CI
# and the version pinned in pyproject.toml for local development.
#
# Required environment variables:
#   LINTRO_IMAGE  - Docker image reference (e.g. ghcr.io/lgtm-hq/py-lintro@sha256:...)
#
# Optional environment variables:
#   PYPROJECT     - Path to pyproject.toml (default: pyproject.toml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../ci/lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

PYPROJECT="${PYPROJECT:-pyproject.toml}"

if [[ -z "${LINTRO_IMAGE:-}" ]]; then
	log_error "LINTRO_IMAGE is not set"
	exit 1
fi

if [[ ! -f "$PYPROJECT" ]]; then
	log_error "pyproject.toml not found at: $PYPROJECT"
	exit 1
fi

# Extract pinned version from pyproject.toml (matches lintro==X.Y.Z)
PYPROJECT_VERSION=$(grep -oE 'lintro==[0-9]+\.[0-9]+\.[0-9]+' "$PYPROJECT" | head -1 | sed 's/lintro==//' || true)
if [[ -z "$PYPROJECT_VERSION" ]]; then
	log_error "Could not find pinned lintro version (lintro==X.Y.Z) in $PYPROJECT"
	log_error "Use an exact pin (==) instead of a minimum version (>=)"
	exit 1
fi

# Extract version from Docker image
log_info "Querying lintro version from Docker image..."
DOCKER_VERSION=$(docker run --rm "$LINTRO_IMAGE" lintro --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ -z "$DOCKER_VERSION" ]]; then
	log_error "Could not determine lintro version from Docker image: $LINTRO_IMAGE"
	exit 1
fi

log_info "pyproject.toml pins: lintro==$PYPROJECT_VERSION"
log_info "Docker image has:    lintro==$DOCKER_VERSION"

if [[ "$PYPROJECT_VERSION" != "$DOCKER_VERSION" ]]; then
	log_error "Version mismatch! pyproject.toml ($PYPROJECT_VERSION) != Docker image ($DOCKER_VERSION)"
	log_error "Update pyproject.toml to: lintro==$DOCKER_VERSION"
	exit 1
fi

log_success "Lintro versions are in sync: $PYPROJECT_VERSION"
