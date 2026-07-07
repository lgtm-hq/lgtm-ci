#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run lintro chk/fmt via full ghcr.io/lgtm-hq/py-lintro image (lintro-tools stack).
#
# Required environment variables:
#   STEP           check | format
#   LINTRO_IMAGE   Pinned reference (e.g. ghcr.io/lgtm-hq/py-lintro@sha256:...)
#
# Optional environment variables:
#   TOOLS          Comma-separated list passed to lintro --tools (empty = all)
#   TOOL_OPTIONS   Comma-separated lintro --tool-options (check only; empty = none)
#   FAIL_ON_ERROR  true|false (default: true) — only for STEP=check
#   WORKSPACE      Absolute path to mount at /code (default: current directory)
#   OUTPUT_LOG     Log path for STEP=check tee (default: chk-output.txt)
#   MAP_HOST_USER  true|false — map host UID/GID via docker --user (default: true
#                  when GITHUB_ACTIONS=true, otherwise unset/false)

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat <<'EOF'
run-lintro-docker.sh — run lintro inside the full py-lintro container.

Requires: STEP=check|format, LINTRO_IMAGE=ghcr.io/lgtm-hq/py-lintro@sha256:...

Optional: TOOLS, TOOL_OPTIONS, FAIL_ON_ERROR, WORKSPACE, OUTPUT_LOG, MAP_HOST_USER

MAP_HOST_USER defaults to true on GitHub Actions so the workspace mount is writable.
Local runs omit --user so the py-lintro entrypoint can gosu to the mount owner.

Matches https://github.com/lgtm-hq/py-lintro documented docker invocation.
EOF
	exit 0
fi

: "${STEP:?STEP is required (check or format)}"
: "${LINTRO_IMAGE:?LINTRO_IMAGE is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

if [[ -f "$LIB_DIR/log.sh" ]]; then
	# shellcheck source=../lib/log.sh
	source "$LIB_DIR/log.sh"
else
	log_info() { echo "[INFO] $*"; }
	log_error() { echo "[ERROR] $*" >&2; }
	log_success() { echo "[SUCCESS] $*"; }
fi

: "${TOOLS:=}"
: "${TOOL_OPTIONS:=}"
: "${FAIL_ON_ERROR:=true}"
: "${WORKSPACE:=$(pwd)}"
: "${OUTPUT_LOG:=chk-output.txt}"
: "${MAP_HOST_USER:=}"
if [[ -z "${MAP_HOST_USER}" ]] && [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
	MAP_HOST_USER=true
fi

log_info "Pulling Lintro image: ${LINTRO_IMAGE}"
set +e
PULL_OUTPUT="$(docker pull "${LINTRO_IMAGE}" 2>&1)"
PULL_EC=$?
set -e
if [[ "${PULL_EC}" -ne 0 ]]; then
	log_error "Failed to pull Lintro image ${LINTRO_IMAGE}: ${PULL_OUTPUT}"
	exit "${PULL_EC}"
fi
printf '%s\n' "${PULL_OUTPUT}"

# MAP_HOST_USER=true (default on GitHub Actions) maps the host UID/GID so bun install
# and tool caches can write to the mounted checkout. Local runs omit --user so the
# py-lintro entrypoint can start as root, adjust PATH, then gosu to the mount owner.
declare -a docker_args=(
	docker run --rm
	-e HOME=/tmp
	-e LINTRO_AUTO_INSTALL_DEPS=1
	-v "${WORKSPACE}:/code"
	-w /code
)
if [[ "${MAP_HOST_USER}" == "true" ]]; then
	docker_args+=(--user "$(id -u):$(id -g)")
fi
docker_args+=("${LINTRO_IMAGE}")

declare -a lintro_args=()

case "$STEP" in
check)
	lintro_args+=(chk)
	if [[ -n "$TOOLS" ]]; then
		lintro_args+=(--tools "${TOOLS}")
	fi
	if [[ -n "$TOOL_OPTIONS" ]]; then
		lintro_args+=(--tool-options "${TOOL_OPTIONS}")
	fi
	lintro_args+=(. --output-format grid)
	log_info "Running lintro check in container..."
	set +e
	set -o pipefail
	"${docker_args[@]}" "${lintro_args[@]}" 2>&1 | tee "${OUTPUT_LOG}"
	DOCKER_EC="${PIPESTATUS[0]}"
	TEE_EC="${PIPESTATUS[1]:-0}"
	if [[ "${TEE_EC}" -ne 0 ]]; then
		log_error "tee failed (exit ${TEE_EC}) while writing ${OUTPUT_LOG}"
	fi
	if [[ "${DOCKER_EC}" -ne 0 ]]; then
		EXIT_CODE="${DOCKER_EC}"
	elif [[ "${TEE_EC}" -ne 0 ]]; then
		EXIT_CODE="${TEE_EC}"
	else
		EXIT_CODE=0
	fi
	set +o pipefail
	set -e
	;;
format)
	lintro_args+=(fmt)
	if [[ -n "$TOOLS" ]]; then
		lintro_args+=(--tools "${TOOLS}")
	fi
	lintro_args+=(.)
	log_info "Running lintro format in container..."
	set +e
	"${docker_args[@]}" "${lintro_args[@]}"
	EXIT_CODE=$?
	set -e
	;;
*)
	log_error "STEP must be check or format, got: ${STEP}"
	exit 2
	;;
esac

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "exit-code=${EXIT_CODE}"
		if [[ "${EXIT_CODE}" -eq 0 ]]; then
			echo "status=passed"
		else
			echo "status=failed"
		fi
	} >>"${GITHUB_OUTPUT}"
fi

if [[ "${EXIT_CODE}" -eq 0 ]]; then
	log_success "Lintro ${STEP} completed successfully"
else
	log_error "Lintro ${STEP} failed with exit code ${EXIT_CODE}"
	if [[ "${STEP}" == "check" ]] && [[ "${FAIL_ON_ERROR}" == "true" ]]; then
		exit "${EXIT_CODE}"
	fi
	if [[ "${STEP}" == "format" ]]; then
		exit "${EXIT_CODE}"
	fi
fi
