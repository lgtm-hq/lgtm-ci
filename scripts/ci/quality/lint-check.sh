#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run lintro quality checks with configurable options
#
# Required environment variables:
#   STEP - Which step to run: check, format, or report
#
# Optional environment variables:
#   TOOLS - Comma-separated list of tools to run (empty = all)
#   FIX - Set to "true" to auto-fix issues (format step only)
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
	: "${VERBOSE:=false}"

	LINTRO_ARGS=("chk")

	if [[ -n "$TOOLS" ]]; then
		LINTRO_ARGS+=("--tools" "$TOOLS")
	fi

	log_info "Running lintro check..."
	if [[ "$VERBOSE" == "true" ]]; then
		uv run lintro "${LINTRO_ARGS[@]}"
	else
		uv run lintro "${LINTRO_ARGS[@]}" 2>&1
	fi

	EXIT_CODE=$?
	if [[ $EXIT_CODE -eq 0 ]]; then
		log_success "All quality checks passed"
	else
		log_error "Quality checks failed with exit code $EXIT_CODE"
	fi

	exit $EXIT_CODE
	;;

format)
	: "${TOOLS:=}"
	: "${FIX:=false}"

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

report)
	: "${TOOLS:=}"

	# Generate lintro report
	LINTRO_ARGS=("chk")

	if [[ -n "$TOOLS" ]]; then
		LINTRO_ARGS+=("--tools" "$TOOLS")
	fi

	log_info "Generating quality report..."

	# Run lintro and capture output (don't fail on lint errors for report)
	set +e
	OUTPUT=$(uv run lintro "${LINTRO_ARGS[@]}" 2>&1)
	EXIT_CODE=$?
	set -e

	# Output for CI consumption
	echo "$OUTPUT"

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

	exit $EXIT_CODE
	;;

*)
	log_error "Unknown step: $STEP"
	echo "Usage: STEP=<check|format|report> $0"
	exit 1
	;;
esac
