#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a smoke test against a built image (build-docker STEP: smoke-test / smoke-test-local)
#
# When LOCAL=false (default), pulls a per-platform staging image by immutable
# digest (IMAGE@sha256:...) to avoid TOCTOU between the build and verify jobs.
# When LOCAL=true, tests a locally loaded image (no registry pull).
#
# Optional environment variables:
#   LOCAL - Test a locally loaded image instead of pulling by digest
#           (default: false)
#
# Required environment variables (LOCAL=false):
#   REGISTRY    - Container registry URL
#   IMAGE_NAME  - Registry-relative image name
#   PLATFORM    - Target platform (e.g. linux/arm64)
#   DIGEST_FILE - Path to a file containing the sha256:... digest of the
#                 staging image (produced by the `record-digest` step)
#
# Required environment variables (LOCAL=true):
#   IMAGE     - Full local image reference (registry/name:tag)
#   PLATFORM  - Target platform (e.g. linux/arm64)
#   REGISTRY  - Container registry URL
#
# Optional environment variables (mutually exclusive; at least one required):
#   SMOKE_TEST        - Shorthand command + args; word-split into `docker run`
#   SMOKE_TEST_SCRIPT - Path to caller-owned script; receives IMAGE, PLATFORM,
#                       REGISTRY in the environment and owns the docker run

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${LOCAL:=false}"
: "${SMOKE_TEST:=}"
: "${SMOKE_TEST_SCRIPT:=}"

if [[ "$LOCAL" == "true" ]]; then
	: "${IMAGE:?IMAGE is required}"
	: "${PLATFORM:?PLATFORM is required}"
	: "${REGISTRY:?REGISTRY is required}"
else
	: "${REGISTRY:?REGISTRY is required}"
	: "${IMAGE_NAME:?IMAGE_NAME is required}"
	: "${PLATFORM:?PLATFORM is required}"
	: "${DIGEST_FILE:?DIGEST_FILE is required}"
fi

if [[ -n "$SMOKE_TEST" && -n "$SMOKE_TEST_SCRIPT" ]]; then
	die "SMOKE_TEST and SMOKE_TEST_SCRIPT are mutually exclusive"
fi
if [[ -z "$SMOKE_TEST" && -z "$SMOKE_TEST_SCRIPT" ]]; then
	die "One of SMOKE_TEST or SMOKE_TEST_SCRIPT is required"
fi

if [[ "$LOCAL" != "true" ]]; then
	if [[ ! -s "$DIGEST_FILE" ]]; then
		die "DIGEST_FILE missing or empty: ${DIGEST_FILE}"
	fi

	digest=$(<"$DIGEST_FILE")
	if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
		die "Invalid digest in ${DIGEST_FILE}: ${digest}"
	fi

	IMAGE="${REGISTRY}/${IMAGE_NAME}@${digest}"
fi

export IMAGE PLATFORM REGISTRY

if [[ "$LOCAL" != "true" ]]; then
	echo "::group::Pulling ${IMAGE} (${PLATFORM})"
	docker pull --platform "${PLATFORM}" "${IMAGE}"
	echo "::endgroup::"
fi

if [[ -n "$SMOKE_TEST_SCRIPT" ]]; then
	if [[ ! -f "$SMOKE_TEST_SCRIPT" ]]; then
		echo "::error::smoke-test-script not found: ${SMOKE_TEST_SCRIPT}"
		exit 1
	fi
	echo "::group::${SMOKE_TEST_SCRIPT} (IMAGE=${IMAGE} PLATFORM=${PLATFORM})"
	chmod +x "$SMOKE_TEST_SCRIPT"
	"./${SMOKE_TEST_SCRIPT#./}"
	echo "::endgroup::"
else
	echo "::group::docker run --rm --platform ${PLATFORM} ${IMAGE} ${SMOKE_TEST}"
	# Intentionally word-split SMOKE_TEST so callers can pass flags+args
	# shellcheck disable=SC2086
	docker run --rm --platform "${PLATFORM}" "${IMAGE}" ${SMOKE_TEST}
	echo "::endgroup::"
fi
