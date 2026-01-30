#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run actionlint to validate GitHub Actions workflows and composite actions
#
# Required environment variables:
#   STEP - Which step to run: check or install
#
# Optional environment variables:
#   PATHS - Space-separated paths to lint (default: .github/)
#   FORMAT - Output format: default, oneline, or json

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
	log_warn() { echo "[WARN] $*" >&2; }
fi

case "$STEP" in
install)
	log_info "Installing actionlint..."

	if command -v actionlint &>/dev/null; then
		log_info "actionlint already installed: $(actionlint --version)"
		exit 0
	fi

	# Try go install first
	if command -v go &>/dev/null; then
		go install github.com/rhysd/actionlint/cmd/actionlint@latest
		log_success "actionlint installed via go"
		exit 0
	fi

	# Fallback to download script
	BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
	mkdir -p "$BIN_DIR"

	curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash -s -- -b "$BIN_DIR"

	if [[ -x "$BIN_DIR/actionlint" ]]; then
		log_success "actionlint installed to $BIN_DIR"

		# Add to PATH for GitHub Actions
		if [[ -n "${GITHUB_PATH:-}" ]]; then
			echo "$BIN_DIR" >>"$GITHUB_PATH"
		fi
	else
		log_error "Failed to install actionlint"
		exit 1
	fi
	;;

check)
	: "${PATHS:=.github/}"
	: "${FORMAT:=default}"

	if ! command -v actionlint &>/dev/null; then
		log_error "actionlint not found. Run with STEP=install first."
		exit 1
	fi

	log_info "Running actionlint on: $PATHS"

	ACTIONLINT_ARGS=("-color")

	case "$FORMAT" in
	oneline)
		ACTIONLINT_ARGS+=("-oneline")
		;;
	json)
		ACTIONLINT_ARGS+=("-format" "{{json .}}")
		;;
	default) ;;
	*)
		log_warn "Unknown format: $FORMAT, using default"
		;;
	esac

	# Run actionlint
	# shellcheck disable=SC2086 # Word splitting intended for PATHS
	actionlint "${ACTIONLINT_ARGS[@]}" $PATHS

	EXIT_CODE=$?
	if [[ $EXIT_CODE -eq 0 ]]; then
		log_success "All GitHub Actions validated"
	else
		log_error "actionlint found issues"
	fi

	exit $EXIT_CODE
	;;

*)
	log_error "Unknown step: $STEP"
	echo "Usage: STEP=<install|check> $0"
	exit 1
	;;
esac
