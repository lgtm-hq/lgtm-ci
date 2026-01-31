#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Scan for vulnerabilities using Grype
#
# Required environment variables:
#   STEP - Which step to run: install, scan, parse, sarif, summary
#   TARGET - Target to scan (SBOM file, image, directory)
#   TARGET_TYPE - Type of target (sbom, image, dir)
#   FAIL_ON - Severity threshold to fail on (critical, high, medium, low, none)

set -euo pipefail

: "${STEP:?STEP is required}"

# Source library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
[[ -f "$LIB_DIR/log.sh" ]] && source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
[[ -f "$LIB_DIR/github.sh" ]] && source "$LIB_DIR/github.sh"
# shellcheck source=../lib/sbom.sh
[[ -f "$LIB_DIR/sbom.sh" ]] && source "$LIB_DIR/sbom.sh"

case "$STEP" in
install)
	# Installation handled by anchore/scan-action
	# This step is for manual/local installs if needed
	: "${GRYPE_VERSION:=latest}"

	if command -v grype >/dev/null 2>&1; then
		log_info "Grype already installed: $(grype version 2>/dev/null | head -1)"
		exit 0
	fi

	log_info "Installing Grype..."

	# Use official installer script
	curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b "${BIN_DIR:-/usr/local/bin}"

	if command -v grype >/dev/null 2>&1; then
		log_success "Grype installed: $(grype version 2>/dev/null | head -1)"
	else
		log_error "Failed to install Grype"
		exit 1
	fi
	;;

scan)
	: "${TARGET:?TARGET is required}"
	: "${TARGET_TYPE:=sbom}"
	: "${FAIL_ON:=}"
	: "${OUTPUT_FILE:=${RUNNER_TEMP:-/tmp}/grype-results.json}"

	# Build grype target based on type
	case "$TARGET_TYPE" in
	sbom)
		if [[ ! -f "$TARGET" ]]; then
			log_error "SBOM file not found: $TARGET"
			exit 1
		fi
		GRYPE_TARGET="sbom:${TARGET}"
		;;
	image | container)
		GRYPE_TARGET="${TARGET}"
		;;
	dir | directory)
		GRYPE_TARGET="dir:${TARGET}"
		;;
	*)
		log_error "Unsupported target type: $TARGET_TYPE"
		exit 1
		;;
	esac

	log_info "Scanning for vulnerabilities: $GRYPE_TARGET"

	# Build grype args
	GRYPE_ARGS=(-o json)
	if [[ -n "$FAIL_ON" && "$FAIL_ON" != "none" ]]; then
		GRYPE_ARGS+=(--fail-on "$FAIL_ON")
	fi

	# Run scan and capture both result and exit code
	set +e
	grype "$GRYPE_TARGET" "${GRYPE_ARGS[@]}" >"$OUTPUT_FILE" 2>&1
	scan_exit_code=$?
	set -e

	# Parse results
	vulnerabilities_found="false"
	critical_count=0
	high_count=0
	medium_count=0
	low_count=0

	if [[ -f "$OUTPUT_FILE" ]] && command -v jq >/dev/null 2>&1; then
		# Count vulnerabilities by severity
		critical_count=$(jq -r '[.matches[]? | select(.vulnerability.severity == "Critical")] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
		high_count=$(jq -r '[.matches[]? | select(.vulnerability.severity == "High")] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
		medium_count=$(jq -r '[.matches[]? | select(.vulnerability.severity == "Medium")] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
		low_count=$(jq -r '[.matches[]? | select(.vulnerability.severity == "Low")] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)

		total=$((critical_count + high_count + medium_count + low_count))
		if [[ $total -gt 0 ]]; then
			vulnerabilities_found="true"
		fi
	fi

	# Set outputs
	set_github_output "vulnerabilities-found" "$vulnerabilities_found"
	set_github_output "critical-count" "$critical_count"
	set_github_output "high-count" "$high_count"
	set_github_output "medium-count" "$medium_count"
	set_github_output "low-count" "$low_count"
	set_github_output "results-file" "$OUTPUT_FILE"

	log_info "Scan complete"
	log_info "Critical: $critical_count, High: $high_count, Medium: $medium_count, Low: $low_count"

	# If fail-on was set and vulnerabilities exceed threshold, exit with grype's exit code
	if [[ $scan_exit_code -ne 0 && -n "$FAIL_ON" && "$FAIL_ON" != "none" ]]; then
		log_error "Vulnerabilities found exceeding threshold: $FAIL_ON"
		exit "$scan_exit_code"
	fi
	;;

parse)
	: "${RESULTS_FILE:=${RUNNER_TEMP:-/tmp}/grype-results.json}"

	if [[ ! -f "$RESULTS_FILE" ]]; then
		log_warn "Results file not found: $RESULTS_FILE"
		exit 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		log_warn "jq not available, skipping parse"
		exit 0
	fi

	# Output vulnerability details
	log_info "Vulnerability Details:"
	jq -r '.matches[]? | "\(.vulnerability.severity): \(.vulnerability.id) in \(.artifact.name)@\(.artifact.version)"' "$RESULTS_FILE" | sort | head -50
	;;

sarif)
	: "${TARGET:?TARGET is required}"
	: "${TARGET_TYPE:=sbom}"
	: "${SARIF_FILE:=${RUNNER_TEMP:-/tmp}/grype-results.sarif}"

	# Build grype target based on type
	case "$TARGET_TYPE" in
	sbom)
		GRYPE_TARGET="sbom:${TARGET}"
		;;
	image | container)
		GRYPE_TARGET="${TARGET}"
		;;
	dir | directory)
		GRYPE_TARGET="dir:${TARGET}"
		;;
	*)
		log_error "Unsupported target type: $TARGET_TYPE"
		exit 1
		;;
	esac

	log_info "Generating SARIF report..."

	# Run grype with SARIF output (never fail here, just generate report)
	grype "$GRYPE_TARGET" -o sarif >"$SARIF_FILE" 2>/dev/null || true

	if [[ -f "$SARIF_FILE" ]]; then
		log_success "SARIF report generated: $SARIF_FILE"
		set_github_output "sarif-file" "$SARIF_FILE"
	else
		log_warn "Failed to generate SARIF report"
	fi
	;;

summary)
	: "${RESULTS_FILE:=${RUNNER_TEMP:-/tmp}/grype-results.json}"
	: "${CRITICAL_COUNT:=0}"
	: "${HIGH_COUNT:=0}"
	: "${MEDIUM_COUNT:=0}"
	: "${LOW_COUNT:=0}"

	add_github_summary "## Vulnerability Scan Summary"
	add_github_summary ""
	add_github_summary "| Severity | Count |"
	add_github_summary "|----------|-------|"
	add_github_summary "| :red_circle: Critical | $CRITICAL_COUNT |"
	add_github_summary "| :orange_circle: High | $HIGH_COUNT |"
	add_github_summary "| :yellow_circle: Medium | $MEDIUM_COUNT |"
	add_github_summary "| :blue_circle: Low | $LOW_COUNT |"
	add_github_summary ""

	total=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))
	if [[ $total -eq 0 ]]; then
		add_github_summary ":white_check_mark: **No vulnerabilities found!**"
	else
		add_github_summary ":warning: **Total: $total vulnerabilities found**"

		# Add top vulnerabilities if results file exists
		if [[ -f "$RESULTS_FILE" ]] && command -v jq >/dev/null 2>&1; then
			add_github_summary ""
			add_github_summary "<details>"
			add_github_summary "<summary>Top Vulnerabilities</summary>"
			add_github_summary ""
			add_github_summary '```'
			jq -r '.matches[]? | "\(.vulnerability.severity): \(.vulnerability.id) in \(.artifact.name)@\(.artifact.version)"' "$RESULTS_FILE" | sort | head -20
			add_github_summary '```'
			add_github_summary ""
			add_github_summary "</details>"
		fi
	fi

	add_github_summary ""
	add_github_summary "> Scanned using [Grype](https://github.com/anchore/grype)"
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
