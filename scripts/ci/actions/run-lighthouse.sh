#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run Lighthouse CI audits
#
# Required environment variables:
#   STEP - Which step to run: setup, run, parse, summary
#
# Optional environment variables:
#   URL - URL to audit (required for run step)
#   CONFIG_PATH - Path to lighthouserc.json
#   OUTPUT_DIR - Directory for results (default: lighthouse-reports)
#   THRESHOLD_PERFORMANCE - Minimum performance score (default: 80)
#   THRESHOLD_ACCESSIBILITY - Minimum accessibility score (default: 90)
#   THRESHOLD_BEST_PRACTICES - Minimum best practices score (default: 80)
#   THRESHOLD_SEO - Minimum SEO score (default: 80)
#   EXTRA_ARGS - Additional arguments to pass to LHCI

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"

case "$STEP" in
setup)
	log_info "Setting up Lighthouse CI..."

	# Check if @lhci/cli is available
	if ! command -v lhci &>/dev/null; then
		log_info "Installing @lhci/cli..."
		bun add -g @lhci/cli
	fi

	# Verify installation
	if command -v lhci &>/dev/null; then
		log_success "Lighthouse CI installed: $(lhci --version)"
	else
		# Try with bunx as fallback
		if bunx @lhci/cli --version &>/dev/null; then
			log_success "Lighthouse CI available via bunx"
		else
			die "Failed to install Lighthouse CI"
		fi
	fi
	;;

run)
	: "${URL:?URL is required for run step}"
	: "${CONFIG_PATH:=}"
	: "${OUTPUT_DIR:=lighthouse-reports}"
	: "${EXTRA_ARGS:=}"

	mkdir -p "$OUTPUT_DIR"

	# Build LHCI command
	LHCI_ARGS=()
	LHCI_ARGS+=("autorun")

	# Use config file if provided, otherwise generate inline config
	if [[ -n "$CONFIG_PATH" ]] && [[ -f "$CONFIG_PATH" ]]; then
		LHCI_ARGS+=("--config=$CONFIG_PATH")
		log_info "Using config from $CONFIG_PATH"
	else
		# Generate minimal config for single URL audit
		log_info "Running audit for URL: $URL"
		LHCI_ARGS+=("--collect.url=$URL")
		LHCI_ARGS+=("--collect.numberOfRuns=1")
		LHCI_ARGS+=("--collect.settings.chromeFlags=--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage")
		LHCI_ARGS+=("--upload.target=filesystem")
		LHCI_ARGS+=("--upload.outputDir=$OUTPUT_DIR")
	fi

	# Add extra args
	if [[ -n "$EXTRA_ARGS" ]]; then
		read -ra EXTRA_ARRAY <<<"$EXTRA_ARGS"
		LHCI_ARGS+=("${EXTRA_ARRAY[@]}")
	fi

	log_info "Running Lighthouse CI..."

	exit_code=0
	if command -v lhci &>/dev/null; then
		lhci "${LHCI_ARGS[@]}" || exit_code=$?
	else
		bunx @lhci/cli "${LHCI_ARGS[@]}" || exit_code=$?
	fi

	# Set outputs
	set_github_output "exit-code" "$exit_code"
	set_github_output "output-dir" "$OUTPUT_DIR"

	# Find the results file
	if [[ -d "$OUTPUT_DIR" ]]; then
		# LHCI creates files like lhr-*.json
		results_file=$(find "$OUTPUT_DIR" -name "lhr-*.json" -type f 2>/dev/null | sort | head -1 || true)
		if [[ -n "$results_file" ]]; then
			set_github_output "results-path" "$results_file"
		fi
	fi

	exit "$exit_code"
	;;

parse)
	: "${RESULTS_PATH:=}"
	: "${OUTPUT_DIR:=lighthouse-reports}"
	: "${THRESHOLD_PERFORMANCE:=80}"
	: "${THRESHOLD_ACCESSIBILITY:=90}"
	: "${THRESHOLD_BEST_PRACTICES:=80}"
	: "${THRESHOLD_SEO:=80}"

	# Find results file if not specified
	if [[ -z "$RESULTS_PATH" ]] || [[ ! -f "$RESULTS_PATH" ]]; then
		if [[ -d "$OUTPUT_DIR" ]]; then
			RESULTS_PATH=$(find "$OUTPUT_DIR" -name "lhr-*.json" -type f 2>/dev/null | sort | head -1 || true)
		fi
	fi

	if [[ -z "$RESULTS_PATH" ]] || [[ ! -f "$RESULTS_PATH" ]]; then
		log_warn "No Lighthouse results found"
		set_github_output "performance" "0"
		set_github_output "accessibility" "0"
		set_github_output "best-practices" "0"
		set_github_output "seo" "0"
		set_github_output "passed" "false"
		exit 0
	fi

	# Parse the results
	parse_lighthouse_json "$RESULTS_PATH"

	# Set score outputs
	set_github_output "performance" "$LH_PERFORMANCE"
	set_github_output "accessibility" "$LH_ACCESSIBILITY"
	set_github_output "best-practices" "$LH_BEST_PRACTICES"
	set_github_output "seo" "$LH_SEO"

	# Check thresholds
	if check_lighthouse_thresholds "$THRESHOLD_PERFORMANCE" "$THRESHOLD_ACCESSIBILITY" "$THRESHOLD_BEST_PRACTICES" "$THRESHOLD_SEO"; then
		set_github_output "passed" "true"
		log_success "All Lighthouse scores meet thresholds"
	else
		set_github_output "passed" "false"
		set_github_output "failed-categories" "$LH_FAILED_CATEGORIES"
		log_warn "Failed categories: $LH_FAILED_CATEGORIES"
	fi

	log_info "Lighthouse scores: $(format_lighthouse_summary)"
	;;

summary)
	: "${PERFORMANCE:=0}"
	: "${ACCESSIBILITY:=0}"
	: "${BEST_PRACTICES:=0}"
	: "${SEO:=0}"
	: "${PASSED:=false}"
	: "${THRESHOLD_PERFORMANCE:=80}"
	: "${THRESHOLD_ACCESSIBILITY:=90}"
	: "${THRESHOLD_BEST_PRACTICES:=80}"
	: "${THRESHOLD_SEO:=80}"

	add_github_summary "## Lighthouse CI Results"
	add_github_summary ""

	if [[ "$PASSED" == "true" ]]; then
		add_github_summary "**Status:** :white_check_mark: All scores meet thresholds"
	else
		add_github_summary "**Status:** :warning: Some scores below thresholds"
	fi
	add_github_summary ""

	# Score emoji helper
	score_icon() {
		local score=$1
		local threshold=$2
		if [[ "$score" -ge "$threshold" ]]; then
			echo ":green_circle:"
		elif [[ "$score" -ge $((threshold - 10)) ]]; then
			echo ":yellow_circle:"
		else
			echo ":red_circle:"
		fi
	}

	add_github_summary "| Category | Score | Threshold |"
	add_github_summary "|----------|-------|-----------|"
	add_github_summary "| $(score_icon "$PERFORMANCE" "$THRESHOLD_PERFORMANCE") Performance | **$PERFORMANCE** | $THRESHOLD_PERFORMANCE |"
	add_github_summary "| $(score_icon "$ACCESSIBILITY" "$THRESHOLD_ACCESSIBILITY") Accessibility | **$ACCESSIBILITY** | $THRESHOLD_ACCESSIBILITY |"
	add_github_summary "| $(score_icon "$BEST_PRACTICES" "$THRESHOLD_BEST_PRACTICES") Best Practices | **$BEST_PRACTICES** | $THRESHOLD_BEST_PRACTICES |"
	add_github_summary "| $(score_icon "$SEO" "$THRESHOLD_SEO") SEO | **$SEO** | $THRESHOLD_SEO |"
	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
