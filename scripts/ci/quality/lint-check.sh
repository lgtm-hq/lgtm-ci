#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run lintro quality checks with configurable options
#
# Required environment variables:
#   STEP - Which step to run: check, format, or report
#
# Optional environment variables:
#   TOOLS - Comma-separated list of tools to run (empty = all)
#   FAIL_ON_ERROR - Set to "true" to exit non-zero on errors (default: true)
#   VERBOSE - Set to "true" for verbose output

set -euo pipefail

: "${STEP:?STEP is required}"

# Source shared libraries if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

if [[ -f "$LIB_DIR/log.sh" ]]; then
	# shellcheck source=../lib/log.sh
	source "$LIB_DIR/log.sh"
else
	log_info() { echo "[INFO] $*"; }
	log_error() { echo "[ERROR] $*" >&2; }
	log_success() { echo "[SUCCESS] $*"; }
fi

case "$STEP" in
check)
	: "${TOOLS:=}"
	: "${FAIL_ON_ERROR:=true}"
	: "${VERBOSE:=false}"

	LINTRO_ARGS=("chk")

	if [[ -n "$TOOLS" ]]; then
		LINTRO_ARGS+=("--tools" "$TOOLS")
	fi

	log_info "Running lintro check..."

	set +e
	if [[ "$VERBOSE" == "true" ]]; then
		uv run lintro "${LINTRO_ARGS[@]}"
	else
		uv run lintro "${LINTRO_ARGS[@]}" 2>&1
	fi
	EXIT_CODE=$?
	set -e

	# Set output for GitHub Actions if available
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			echo "exit-code=$EXIT_CODE"
			if [[ $EXIT_CODE -eq 0 ]]; then
				echo "status=passed"
			else
				echo "status=failed"
			fi
		} >>"$GITHUB_OUTPUT"
	fi

	if [[ $EXIT_CODE -eq 0 ]]; then
		log_success "All quality checks passed"
	else
		log_error "Quality checks failed with exit code $EXIT_CODE"
		if [[ "$FAIL_ON_ERROR" == "true" ]]; then
			exit $EXIT_CODE
		fi
	fi
	;;

format)
	: "${TOOLS:=}"

	LINTRO_ARGS=("fmt")

	if [[ -n "$TOOLS" ]]; then
		LINTRO_ARGS+=("--tools" "$TOOLS")
	fi

	log_info "Running lintro format..."
	uv run lintro "${LINTRO_ARGS[@]}"

	EXIT_CODE=$?
	if [[ $EXIT_CODE -eq 0 ]]; then
		log_success "Formatting complete"
	else
		log_error "Formatting failed with exit code $EXIT_CODE"
	fi

	exit $EXIT_CODE
	;;

*)
	log_error "Unknown step: $STEP"
	echo "Usage: STEP=<check|format> $0"
	exit 1
	;;
esac
