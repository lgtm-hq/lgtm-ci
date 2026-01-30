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

	# Pinned version for reproducibility (matches ACTIONLINT_SHA below)
	ACTIONLINT_VERSION="v1.7.7"

	# Try go install first with pinned version
	if command -v go &>/dev/null; then
		go install "github.com/rhysd/actionlint/cmd/actionlint@${ACTIONLINT_VERSION}"
		# Verify installation succeeded and binary is on PATH
		if command -v actionlint &>/dev/null; then
			log_success "actionlint installed via go"
			exit 0
		fi
		log_warn "go install completed but actionlint not found on PATH, falling back to download"
	fi

	# Fallback to download script
	# Pinned to specific commit SHA for supply chain security
	BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
	mkdir -p "$BIN_DIR"

	# Download script to temp file first, then execute (avoid curl | bash)
	DOWNLOAD_SCRIPT=$(mktemp)
	# Using v1.7.7 release commit - update SHA when upgrading actionlint version
	ACTIONLINT_SHA="03d0035246f3e81f36aed592ffb4bebf33a03106"
	curl -fsSL "https://raw.githubusercontent.com/rhysd/actionlint/${ACTIONLINT_SHA}/scripts/download-actionlint.bash" \
		-o "$DOWNLOAD_SCRIPT"
	# Script usage: bash download-actionlint.bash [VERSION] [DIR]
	bash "$DOWNLOAD_SCRIPT" "${ACTIONLINT_VERSION#v}" "$BIN_DIR"
	rm -f "$DOWNLOAD_SCRIPT"

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

	# Run actionlint (disable errexit to capture exit code)
	set +e
	# shellcheck disable=SC2086 # Word splitting intended for PATHS
	actionlint "${ACTIONLINT_ARGS[@]}" $PATHS
	EXIT_CODE=$?
	set -e

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
