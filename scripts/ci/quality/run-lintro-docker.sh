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
#   FAIL_ON_ERROR  true|false (default: true) — only for STEP=check
#   WORKSPACE      Absolute path to mount at /code (default: current directory)
#   OUTPUT_LOG     Log path for STEP=check tee (default: chk-output.txt)

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat <<'EOF'
run-lintro-docker.sh — run lintro inside the full py-lintro container.

Requires: STEP=check|format, LINTRO_IMAGE=ghcr.io/lgtm-hq/py-lintro@sha256:...

Optional: TOOLS, FAIL_ON_ERROR, WORKSPACE, OUTPUT_LOG

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
: "${FAIL_ON_ERROR:=true}"
: "${WORKSPACE:=$(pwd)}"
: "${OUTPUT_LOG:=chk-output.txt}"

log_info "Pulling Lintro image: ${LINTRO_IMAGE}"
docker pull "${LINTRO_IMAGE}"

# Do not pass --user: py-lintro entrypoint starts as root, adjusts PATH for bun/cargo,
# then gosu(1)s to the UID owning /code (the workspace mount). Passing --user skips that
# root entrypoint and caused many external CLIs to be missing from PATH inside the container.
declare -a docker_args=(
	docker run --rm
	-e HOME=/tmp
	-e LINTRO_AUTO_INSTALL_DEPS=1
	-v "${WORKSPACE}:/code"
	-w /code
	"${LINTRO_IMAGE}"
)

declare -a lintro_args=()

case "$STEP" in
check)
	lintro_args+=(chk)
	if [[ -n "$TOOLS" ]]; then
		lintro_args+=(--tools "${TOOLS}")
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
		EXIT_CODE="${TEE_EC}"
	else
		EXIT_CODE="${DOCKER_EC}"
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
