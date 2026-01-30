#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run shellcheck with detailed reporting for CI
#
# Required environment variables:
#   STEP - Which step to run: check or summary
#
# Optional environment variables:
#   PATHS - Space-separated paths to check (default: scripts/)
#   SEVERITY - Minimum severity: error, warning, info, style (default: warning)
#   FORMAT - Output format: tty, gcc, checkstyle, json, diff (default: tty)

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
	: "${PATHS:=scripts/}"
	: "${SEVERITY:=warning}"
	: "${FORMAT:=tty}"

	if ! command -v shellcheck &>/dev/null; then
		log_error "shellcheck not found"
		exit 1
	fi

	log_info "Running shellcheck on: $PATHS"
	log_info "Minimum severity: $SEVERITY"

	# Find all shell scripts
	SHELL_FILES=()
	for path in $PATHS; do
		if [[ -d "$path" ]]; then
			while IFS= read -r -d '' file; do
				SHELL_FILES+=("$file")
			done < <(find "$path" -type f \( -name "*.sh" -o -name "*.bash" \) -print0 2>/dev/null)
		elif [[ -f "$path" ]]; then
			SHELL_FILES+=("$path")
		fi
	done

	if [[ ${#SHELL_FILES[@]} -eq 0 ]]; then
		log_info "No shell files found to check"
		exit 0
	fi

	log_info "Found ${#SHELL_FILES[@]} shell files"

	# Run shellcheck
	set +e
	shellcheck --severity="$SEVERITY" --format="$FORMAT" "${SHELL_FILES[@]}"
	EXIT_CODE=$?
	set -e

	if [[ $EXIT_CODE -eq 0 ]]; then
		log_success "All shell scripts passed shellcheck"
	else
		log_error "shellcheck found issues"
	fi

	exit $EXIT_CODE
	;;

summary)
	: "${PATHS:=scripts/}"

	if ! command -v shellcheck &>/dev/null; then
		log_error "shellcheck not found"
		exit 1
	fi

	# Count issues by severity
	SHELL_FILES=()
	for path in $PATHS; do
		if [[ -d "$path" ]]; then
			while IFS= read -r -d '' file; do
				SHELL_FILES+=("$file")
			done < <(find "$path" -type f \( -name "*.sh" -o -name "*.bash" \) -print0 2>/dev/null)
		elif [[ -f "$path" ]]; then
			SHELL_FILES+=("$path")
		fi
	done

	if [[ ${#SHELL_FILES[@]} -eq 0 ]]; then
		echo "No shell files found"
		exit 0
	fi

	# Get JSON output for parsing
	set +e
	OUTPUT=$(shellcheck --format=json "${SHELL_FILES[@]}" 2>/dev/null)
	set -e

	if [[ -z "$OUTPUT" || "$OUTPUT" == "[]" ]]; then
		echo "## Shellcheck Summary"
		echo ""
		echo "✅ No issues found in ${#SHELL_FILES[@]} files"
	else
		# Count by level using jq if available
		if command -v jq &>/dev/null; then
			ERRORS=$(echo "$OUTPUT" | jq '[.[] | select(.level == "error")] | length')
			WARNINGS=$(echo "$OUTPUT" | jq '[.[] | select(.level == "warning")] | length')
			INFOS=$(echo "$OUTPUT" | jq '[.[] | select(.level == "info")] | length')
			STYLES=$(echo "$OUTPUT" | jq '[.[] | select(.level == "style")] | length')

			echo "## Shellcheck Summary"
			echo ""
			echo "| Severity | Count |"
			echo "|----------|-------|"
			echo "| 🔴 Errors | $ERRORS |"
			echo "| 🟡 Warnings | $WARNINGS |"
			echo "| 🔵 Info | $INFOS |"
			echo "| ⚪ Style | $STYLES |"
		else
			echo "## Shellcheck Summary"
			echo ""
			echo "Issues found (install jq for detailed breakdown)"
		fi
	fi
	;;

*)
	log_error "Unknown step: $STEP"
	echo "Usage: STEP=<check|summary> $0"
	exit 1
	;;
esac
