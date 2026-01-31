#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate coverage badge SVG/JSON for README display
#
# Required environment variables:
#   STEP - Which step to run: calculate, generate, summary
#
# Optional environment variables:
#   COVERAGE_FILE - Path to coverage file (for extracting percentage)
#   COVERAGE_PERCENT - Coverage percentage (if not extracting from file)
#   FORMAT - Badge format: svg, json, shields (default: svg)
#   OUTPUT_PATH - Output path for badge file (default: badge.svg)
#   LABEL - Badge label (default: coverage)
#   RED_THRESHOLD - Threshold for red badge (default: 50)
#   YELLOW_THRESHOLD - Threshold for yellow badge (default: 80)
#   WORKING_DIRECTORY - Directory to run in

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"

case "$STEP" in
calculate)
	: "${COVERAGE_FILE:=}"
	: "${COVERAGE_PERCENT:=}"
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Get coverage percentage from file or use provided value
	if [[ -n "$COVERAGE_FILE" ]] && [[ -f "$COVERAGE_FILE" ]]; then
		coverage=$(extract_coverage_percent "$COVERAGE_FILE")
		log_info "Extracted coverage from $COVERAGE_FILE: ${coverage}%"
	elif [[ -n "$COVERAGE_PERCENT" ]]; then
		coverage="$COVERAGE_PERCENT"
		log_info "Using provided coverage: ${coverage}%"
	else
		log_error "Either COVERAGE_FILE or COVERAGE_PERCENT must be provided"
		exit 1
	fi

	set_github_output "coverage-percent" "$coverage"

	# Determine color
	: "${RED_THRESHOLD:=50}"
	: "${YELLOW_THRESHOLD:=80}"
	color=$(get_badge_color "$coverage" "$RED_THRESHOLD" "$YELLOW_THRESHOLD")
	set_github_output "badge-color" "$color"

	log_info "Badge color: $color"
	;;

generate)
	: "${COVERAGE_PERCENT:=0}"
	: "${FORMAT:=svg}"
	: "${OUTPUT_PATH:=}"
	: "${LABEL:=coverage}"
	: "${RED_THRESHOLD:=50}"
	: "${YELLOW_THRESHOLD:=80}"
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Determine output path based on format
	if [[ -z "$OUTPUT_PATH" ]]; then
		case "$FORMAT" in
		svg) OUTPUT_PATH="coverage-badge.svg" ;;
		json) OUTPUT_PATH="coverage-badge.json" ;;
		shields) OUTPUT_PATH="coverage-badge.json" ;;
		*) OUTPUT_PATH="coverage-badge.svg" ;;
		esac
	fi

	# Ensure output directory exists
	output_dir=$(dirname "$OUTPUT_PATH")
	if [[ "$output_dir" != "." ]] && [[ ! -d "$output_dir" ]]; then
		mkdir -p "$output_dir"
	fi

	log_info "Generating $FORMAT badge for ${COVERAGE_PERCENT}% coverage..."

	case "$FORMAT" in
	svg)
		generate_badge_svg "$COVERAGE_PERCENT" "$OUTPUT_PATH" "$LABEL" "$RED_THRESHOLD" "$YELLOW_THRESHOLD"
		;;
	json | shields)
		generate_badge_json "$COVERAGE_PERCENT" "$OUTPUT_PATH" "$LABEL" "$RED_THRESHOLD" "$YELLOW_THRESHOLD"
		;;
	*)
		log_error "Unsupported badge format: $FORMAT"
		exit 1
		;;
	esac

	if [[ -f "$OUTPUT_PATH" ]]; then
		log_success "Badge generated: $OUTPUT_PATH"
		set_github_output "badge-file" "$OUTPUT_PATH"

		# Generate shields.io URL as well
		shields_url=$(get_shields_url "$COVERAGE_PERCENT" "$LABEL")
		set_github_output "badge-url" "$shields_url"
		log_info "Shields.io URL: $shields_url"
	else
		log_error "Failed to generate badge"
		exit 1
	fi
	;;

summary)
	: "${COVERAGE_PERCENT:=0}"
	: "${BADGE_FILE:=}"
	: "${BADGE_URL:=}"

	add_github_summary "## Coverage Badge"
	add_github_summary ""

	if [[ -n "$BADGE_FILE" ]]; then
		# If badge is SVG, we can't embed it directly in summary
		# but we can reference it or show the shields.io badge
		add_github_summary "Coverage: **${COVERAGE_PERCENT}%**"
		add_github_summary ""

		if [[ -n "$BADGE_URL" ]]; then
			add_github_summary "![Coverage Badge]($BADGE_URL)"
		fi

		add_github_summary ""
		add_github_summary "Badge file: \`$BADGE_FILE\`"
	else
		add_github_summary "Coverage: **${COVERAGE_PERCENT}%**"
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
