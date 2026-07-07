#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Shared health-check helpers for build-docker per-step scripts
#
# Provides parse_duration_seconds and run_health_check for the classify,
# health-check and health-check-local steps. Intended to be sourced after
# lib/actions.sh (for die/log_success).

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_DOCKER_HEALTH_LIB_LOADED:-}" ]] && return 0
readonly _LGTM_CI_DOCKER_HEALTH_LIB_LOADED=1

_DOCKER_HEALTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/network/port.sh
source "$_DOCKER_HEALTH_LIB_DIR/../../lib/network/port.sh"

# Parse a duration string (e.g. 30s) into whole seconds.
parse_duration_seconds() {
	local raw="${1:-30s}"

	if [[ "$raw" =~ ^([0-9]+)s$ ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$raw" =~ ^[0-9]+$ ]]; then
		echo "$raw"
	else
		die "Invalid HEALTH_CHECK_TIMEOUT: ${raw} (use e.g. 30s)"
	fi
}

# Run a detached-container health check against IMAGE.
run_health_check() {
	: "${IMAGE:?IMAGE is required}"
	: "${HEALTH_CHECK_CMD:?HEALTH_CHECK_CMD is required}"
	: "${HEALTH_CHECK_TIMEOUT:=30s}"
	: "${HEALTH_CHECK_PORT:=}"
	: "${PLATFORM:=}"

	local timeout_secs container_id=""
	timeout_secs=$(parse_duration_seconds "$HEALTH_CHECK_TIMEOUT")

	cleanup_health_check_container() {
		if [[ -n "$container_id" ]]; then
			echo "::group::Container logs (${container_id})"
			docker logs "$container_id" 2>&1 || true
			echo "::endgroup::"
			docker rm -f "$container_id" >/dev/null 2>&1 || true
			container_id=""
		fi
	}
	trap cleanup_health_check_container EXIT

	local -a run_opts=(-d)
	if [[ -n "$HEALTH_CHECK_PORT" ]]; then
		run_opts+=(-p "127.0.0.1:${HEALTH_CHECK_PORT}:${HEALTH_CHECK_PORT}")
	fi
	if [[ -n "$PLATFORM" ]]; then
		run_opts+=(--platform "${PLATFORM}")
	fi

	echo "::group::Starting container from ${IMAGE}"
	container_id=$(docker run "${run_opts[@]}" "${IMAGE}")
	echo "::endgroup::"

	if [[ -n "$HEALTH_CHECK_PORT" ]]; then
		echo "::group::Waiting for port ${HEALTH_CHECK_PORT}"
		if ! wait_for_port_listen "$HEALTH_CHECK_PORT" "$timeout_secs" 1; then
			die "Port ${HEALTH_CHECK_PORT} not ready within ${HEALTH_CHECK_TIMEOUT}"
		fi
		echo "::endgroup::"
	fi

	echo "::group::Health check command (runner): <redacted>"
	# Run on the runner against the published localhost port so distroless images
	# do not need curl/wget inside the container.
	if ! timeout "${timeout_secs}s" bash -c "$HEALTH_CHECK_CMD"; then
		local cmd_exit=$?
		if [[ "$cmd_exit" -eq 124 ]]; then
			die "Health check command timed out after ${HEALTH_CHECK_TIMEOUT}"
		fi
		die "Health check command failed (exit ${cmd_exit})"
	fi
	echo "::endgroup::"

	trap - EXIT
	cleanup_health_check_container
	log_success "Health check passed for ${IMAGE}"
}
