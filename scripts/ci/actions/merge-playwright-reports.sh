#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Merge multiple Playwright JSON/HTML reports from shards or matrix jobs
#
# Required environment variables:
#   STEP - Which step to run: collect, merge, summary
#
# Optional environment variables:
#   INPUT_DIR - Directory containing report artifacts (default: playwright-reports)
#   OUTPUT_DIR - Directory for merged report (default: merged-report)
#   REPORT_FORMAT - Format: json, html (default: html)

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"

case "$STEP" in
collect)
	: "${INPUT_DIR:=playwright-reports}"
	: "${OUTPUT_DIR:=merged-report}"

	log_info "Collecting Playwright reports from $INPUT_DIR..."

	if [[ ! -d "$INPUT_DIR" ]]; then
		log_warn "Input directory not found: $INPUT_DIR"
		set_github_output "report-count" "0"
		exit 0
	fi

	# Count blob reports (from sharded runs)
	blob_count=$(find "$INPUT_DIR" -name "*.zip" -type f 2>/dev/null | wc -l | tr -d ' ')
	json_count=$(find "$INPUT_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')

	log_info "Found $blob_count blob reports and $json_count JSON reports"

	set_github_output "blob-count" "$blob_count"
	set_github_output "json-count" "$json_count"
	set_github_output "report-count" "$((blob_count + json_count))"
	;;

merge)
	: "${INPUT_DIR:=playwright-reports}"
	: "${OUTPUT_DIR:=merged-report}"
	: "${REPORT_FORMAT:=html}"

	mkdir -p "$OUTPUT_DIR"

	# Check for blob reports (from sharded runs with blob reporter)
	blob_reports=$(find "$INPUT_DIR" -name "*.zip" -type f 2>/dev/null || true)

	if [[ -n "$blob_reports" ]]; then
		log_info "Merging blob reports into $REPORT_FORMAT format..."

		# Playwright merge-reports command handles blob reports
		merge_args=("merge-reports")
		merge_args+=("--reporter=$REPORT_FORMAT")

		# Add all blob directories
		for blob_dir in "$INPUT_DIR"/*/; do
			if [[ -d "$blob_dir" ]]; then
				merge_args+=("$blob_dir")
			fi
		done

		bunx playwright "${merge_args[@]}"

		# Move output to target directory
		if [[ "$REPORT_FORMAT" == "html" ]] && [[ -d "playwright-report" ]]; then
			mv playwright-report/* "$OUTPUT_DIR/" 2>/dev/null || true
		fi
	else
		# Fallback: merge JSON reports manually
		log_info "Merging JSON reports..."

		json_files=$(find "$INPUT_DIR" -name "*.json" -type f 2>/dev/null || true)

		if [[ -z "$json_files" ]]; then
			log_warn "No reports found to merge"
			set_github_output "merged-path" ""
			exit 0
		fi

		# Combine JSON reports using jq
		# Create array of all test results
		combined_file="$OUTPUT_DIR/merged-results.json"

		# Initialize with first file structure, then merge tests
		first_file=$(echo "$json_files" | head -1)
		cp "$first_file" "$combined_file"

		# Aggregate stats from all files
		total_passed=0
		total_failed=0
		total_skipped=0
		total_duration=0

		while IFS= read -r file; do
			if [[ -f "$file" ]]; then
				parse_playwright_json "$file"
				total_passed=$((total_passed + TESTS_PASSED))
				total_failed=$((total_failed + TESTS_FAILED))
				total_skipped=$((total_skipped + TESTS_SKIPPED))
				total_duration=$((total_duration + TESTS_DURATION))
			fi
		done <<<"$json_files"

		# Update combined file with aggregated stats
		jq --argjson passed "$total_passed" \
			--argjson failed "$total_failed" \
			--argjson skipped "$total_skipped" \
			--argjson duration "$total_duration" \
			'.stats.expected = $passed | .stats.unexpected = $failed | .stats.skipped = $skipped | .stats.duration = ($duration * 1000)' \
			"$combined_file" >"$combined_file.tmp" && mv "$combined_file.tmp" "$combined_file"
	fi

	# Set outputs
	if [[ -f "$OUTPUT_DIR/merged-results.json" ]]; then
		set_github_output "merged-path" "$OUTPUT_DIR/merged-results.json"
	elif [[ -f "$OUTPUT_DIR/index.html" ]]; then
		set_github_output "merged-path" "$OUTPUT_DIR"
	else
		set_github_output "merged-path" "$OUTPUT_DIR"
	fi

	log_success "Reports merged to $OUTPUT_DIR"
	;;

summary)
	: "${TOTAL_PASSED:=0}"
	: "${TOTAL_FAILED:=0}"
	: "${TOTAL_SKIPPED:=0}"
	: "${REPORT_COUNT:=0}"

	total=$((TOTAL_PASSED + TOTAL_FAILED + TOTAL_SKIPPED))

	add_github_summary "## Playwright Merged Results"
	add_github_summary ""

	if [[ "$TOTAL_FAILED" -eq 0 ]]; then
		add_github_summary "**Status:** :white_check_mark: All tests passed"
	else
		add_github_summary "**Status:** :x: $TOTAL_FAILED tests failed"
	fi
	add_github_summary ""

	add_github_summary "| Metric | Value |"
	add_github_summary "|--------|-------|"
	add_github_summary "| Reports merged | $REPORT_COUNT |"
	add_github_summary "| Passed | $TOTAL_PASSED |"
	add_github_summary "| Failed | $TOTAL_FAILED |"
	add_github_summary "| Skipped | $TOTAL_SKIPPED |"
	add_github_summary "| Total | $total |"
	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
