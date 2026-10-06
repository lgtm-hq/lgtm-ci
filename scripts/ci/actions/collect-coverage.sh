#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregate coverage from multiple sources and formats
#
# Required environment variables:
#   STEP - Which step to run: detect, merge, convert, summary
#
# Optional environment variables:
#   COVERAGE_FILES - Glob pattern or comma-separated list of coverage files
#   INPUT_FORMAT - Input format: auto, istanbul, coverage-py, lcov (default: auto)
#   OUTPUT_FORMAT - Output format: json, lcov, cobertura; empty keeps the input
#                   format (default: empty). A requested format with no
#                   converter exits 2 (#1078).
#   MERGE_STRATEGY - How to merge: union, intersection (default: union)
#   OUTPUT_FILE - Output file path (default: merged-coverage.<json|lcov|xml>)
#   WORKING_DIRECTORY - Directory to run in
#
# Exit codes:
#   1 - invalid input (no files, mixed formats, unreadable content, tool failure)
#   2 - unsupported coverage conversion: <src> -> <dst>

set -euo pipefail

# Exit code for a requested output format this script cannot produce
readonly EXIT_UNSUPPORTED_CONVERSION=2

# Default merged-file name for a format
merged_output_name() {
	case "${1:-}" in
	lcov) echo "merged-coverage.lcov" ;;
	cobertura) echo "merged-coverage.xml" ;;
	*) echo "merged-coverage.json" ;;
	esac
}

# Fail by name when no converter exists for src -> dst
require_conversion_supported() {
	local src="${1:-}" dst="${2:-}"
	if ! coverage_conversion_supported "$src" "$dst"; then
		echo "::error::unsupported coverage conversion: $src -> $dst"
		log_error "No converter implements $src -> $dst; leave OUTPUT_FORMAT empty to keep the input format"
		exit "$EXIT_UNSUPPORTED_CONVERSION"
	fi
}

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"

case "$STEP" in
detect)
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Find all coverage files
	coverage_files=()

	# Look for common coverage file patterns
	while IFS= read -r -d '' file; do
		coverage_files+=("$file")
	done < <(find . -maxdepth 3 \( \
		-name "coverage.json" -o \
		-name "coverage.xml" -o \
		-name "coverage.lcov" -o \
		-name "lcov.info" -o \
		-name "coverage-summary.json" -o \
		-name ".coverage" \
		\) -print0 2>/dev/null || true)

	if [[ ${#coverage_files[@]} -eq 0 ]]; then
		log_warn "No coverage files found"
		set_github_output "files-found" "0"
		set_github_output "coverage-files" ""
		exit 0
	fi

	log_info "Found ${#coverage_files[@]} coverage file(s):"
	for file in "${coverage_files[@]}"; do
		# Guard against detect_coverage_format returning non-zero
		format=$(detect_coverage_format "$file" 2>/dev/null) || format="unknown"
		log_info "  - $file ($format)"
	done

	# Join files with newlines for output
	files_list=$(printf "%s\n" "${coverage_files[@]}")

	set_github_output "files-found" "${#coverage_files[@]}"
	set_github_output_multiline "coverage-files" "$files_list"
	;;

merge)
	: "${COVERAGE_FILES:=}"
	: "${INPUT_FORMAT:=auto}"
	: "${OUTPUT_FORMAT:=}"
	: "${MERGE_STRATEGY:=union}"
	: "${OUTPUT_FILE:=}"
	: "${WORKING_DIRECTORY:=.}"

	# Validate OUTPUT_FORMAT early so a typo fails before any merging work;
	# empty means "same as the input format" (#1078)
	case "$OUTPUT_FORMAT" in
	"" | json | lcov | cobertura) ;;
	*)
		log_error "Invalid OUTPUT_FORMAT: $OUTPUT_FORMAT (must be json, lcov, cobertura, or empty for same-as-input)"
		exit 1
		;;
	esac

	# Validate MERGE_STRATEGY (only 'union' is currently implemented)
	case "$MERGE_STRATEGY" in
	union) ;;
	intersection)
		log_error "MERGE_STRATEGY 'intersection' is not yet implemented"
		log_error "Please use 'union' (the default) or contribute an implementation"
		exit 1
		;;
	*)
		log_error "Invalid MERGE_STRATEGY: $MERGE_STRATEGY (must be 'union')"
		exit 1
		;;
	esac

	cd "$WORKING_DIRECTORY"

	# Parse coverage files (comma-separated or newline-separated)
	# Supports glob patterns that will be expanded
	patterns=()
	if [[ "$COVERAGE_FILES" == *","* ]]; then
		# Comma-separated
		IFS=',' read -ra patterns <<<"$COVERAGE_FILES"
	else
		# Newline-separated
		mapfile -t patterns <<<"$COVERAGE_FILES"
	fi

	# Expand glob patterns and filter to existing files
	existing_files=()
	for pattern in "${patterns[@]}"; do
		# Trim whitespace
		pattern="${pattern#"${pattern%%[![:space:]]*}"}"
		pattern="${pattern%"${pattern##*[![:space:]]}"}"
		[[ -z "$pattern" ]] && continue

		# Expand glob pattern (nullglob-safe)
		shopt -s nullglob
		# shellcheck disable=SC2206
		expanded=($pattern)
		shopt -u nullglob

		if [[ ${#expanded[@]} -eq 0 ]]; then
			# No matches for pattern - check if it's a literal file
			if [[ -f "$pattern" ]]; then
				existing_files+=("$pattern")
			else
				log_warn "No files matched pattern: $pattern"
			fi
		else
			for file in "${expanded[@]}"; do
				if [[ -f "$file" ]]; then
					existing_files+=("$file")
				fi
			done
		fi
	done

	if [[ ${#existing_files[@]} -eq 0 ]]; then
		log_error "No valid coverage files found"
		exit 1
	fi

	log_info "Merging ${#existing_files[@]} coverage files..."

	# Determine input format from files if auto
	if [[ "$INPUT_FORMAT" == "auto" ]]; then
		INPUT_FORMAT=$(detect_coverage_format "${existing_files[0]}") || {
			log_error "Cannot detect coverage format: ${existing_files[0]}"
			exit 1
		}

		# Validate all files have the same format
		for file in "${existing_files[@]:1}"; do
			file_format=$(detect_coverage_format "$file") || {
				log_error "Cannot detect coverage format: $file"
				exit 1
			}
			if [[ "$file_format" != "$INPUT_FORMAT" ]]; then
				log_error "Mixed coverage formats detected:"
				log_error "  - ${existing_files[0]}: $INPUT_FORMAT"
				log_error "  - $file: $file_format"
				log_error "Please specify INPUT_FORMAT explicitly or supply consistent files"
				exit 1
			fi
		done
	fi

	# Detection trusts the extension; check the content matches before any of
	# it is merged, so a mislabeled file fails by name instead of yielding an
	# empty report (#1078). An lcov/istanbul/json label is a claim about the
	# content and is checked as such; the coverage-py/cobertura label covers
	# coverage.xml, JSON reports and .coverage data files alike (the merge
	# below re-detects which), so those are checked against what they
	# detect as.
	for file in "${existing_files[@]}"; do
		case "$INPUT_FORMAT" in
		coverage-py | cobertura)
			file_format=$(detect_coverage_format "$file" 2>/dev/null) || file_format="$INPUT_FORMAT"
			;;
		*)
			file_format="$INPUT_FORMAT"
			;;
		esac
		if ! validate_coverage_file "$file" "$file_format"; then
			log_error "Coverage file is not valid $file_format: $file"
			exit 1
		fi
	done

	# Refuse an output nothing can produce before any merge work, so the
	# exit-2 contract holds even when the merge itself would fail first (for
	# example full LCOV without the lcov binary). Only formats whose merge
	# result is fixed are checked here; coverage-py/cobertura inputs can
	# merge to json or xml, so they are checked on the merged result below.
	if [[ -n "$OUTPUT_FORMAT" ]]; then
		case "$INPUT_FORMAT" in
		lcov) require_conversion_supported "lcov" "$OUTPUT_FORMAT" ;;
		istanbul | json) require_conversion_supported "istanbul" "$OUTPUT_FORMAT" ;;
		esac
	fi

	# Create temp file for merging in input format
	temp_merged=$(mktemp)
	trap 'rm -f "$temp_merged"' EXIT

	# Track the actual format of the merged temp file (may differ from INPUT_FORMAT)
	MERGED_FORMAT="$INPUT_FORMAT"

	# Merge based on input format
	case "$INPUT_FORMAT" in
	lcov)
		merge_lcov_files "$temp_merged" "${existing_files[@]}"
		MERGED_FORMAT="lcov"
		;;
	istanbul | json)
		merge_istanbul_files "$temp_merged" "${existing_files[@]}"
		MERGED_FORMAT="istanbul"
		;;
	coverage-py | cobertura)
		# Check if files are .coverage binary data files (for coverage combine)
		all_binary=true
		for file in "${existing_files[@]}"; do
			# Data files are SQLite; a ".coverage.json" report is not one
			if ! is_coverage_py_data_file "$file"; then
				all_binary=false
				break
			fi
		done

		if [[ ${#existing_files[@]} -eq 1 ]] && is_coverage_py_data_file "${existing_files[0]}"; then
			# A lone .coverage data file is SQLite; render it to a report so the
			# output is never binary data under a .json name (#1078)
			if ! command -v coverage &>/dev/null; then
				log_error "Cannot read coverage.py data file without the coverage CLI: ${existing_files[0]}"
				log_error "Install coverage, or produce a JSON/XML report in the test job instead"
				exit 1
			fi
			# Render straight to the requested output when the CLI can, so a
			# coverage-py -> lcov request does not detour through JSON
			render_format="${OUTPUT_FORMAT:-}"
			if [[ -z "$render_format" ]]; then
				[[ "$INPUT_FORMAT" == "cobertura" ]] && render_format="cobertura" || render_format="json"
			fi
			case "$render_format" in
			lcov)
				COVERAGE_FILE="${existing_files[0]}" coverage lcov -o "$temp_merged"
				MERGED_FORMAT="lcov"
				;;
			cobertura)
				COVERAGE_FILE="${existing_files[0]}" coverage xml -o "$temp_merged"
				MERGED_FORMAT="cobertura"
				;;
			*)
				COVERAGE_FILE="${existing_files[0]}" coverage json -o "$temp_merged"
				MERGED_FORMAT="json"
				;;
			esac
		elif [[ ${#existing_files[@]} -eq 1 ]]; then
			cp "${existing_files[0]}" "$temp_merged"
			# Detect actual format of the copied report; only report formats
			# the rest of the pipeline reads may leave this branch
			MERGED_FORMAT=$(detect_coverage_format "$temp_merged" 2>/dev/null) || MERGED_FORMAT="$INPUT_FORMAT"
			case "$MERGED_FORMAT" in
			json | istanbul | coverage-py | cobertura) ;;
			*)
				log_error "Cannot use a $MERGED_FORMAT file under the $INPUT_FORMAT label: ${existing_files[0]}"
				exit 1
				;;
			esac
		elif [[ "$all_binary" == "true" ]] && command -v coverage &>/dev/null; then
			# Only use coverage combine for actual .coverage binary files
			# Use --keep to preserve original files for debugging/re-runs
			coverage combine --keep "${existing_files[@]}"
			case "$INPUT_FORMAT" in
			coverage-py)
				coverage json -o "$temp_merged"
				MERGED_FORMAT="json"
				;;
			cobertura)
				coverage xml -o "$temp_merged"
				MERGED_FORMAT="cobertura"
				;;
			*)
				coverage json -o "$temp_merged"
				MERGED_FORMAT="json"
				;;
			esac
		else
			# Files are XML/JSON reports, not binary - can't use coverage combine
			log_error "Cannot merge ${#existing_files[@]} coverage-py/cobertura files"
			log_error "Files are XML/JSON reports, not .coverage binary data"
			log_error "To merge these files, convert to LCOV format first or use a single file"
			log_error "Rejected files: ${existing_files[*]}"
			exit 1
		fi
		;;
	*)
		log_error "Unsupported input format for merging: $INPUT_FORMAT"
		exit 1
		;;
	esac

	# Empty OUTPUT_FORMAT keeps whatever the merge produced (#1078)
	if [[ -z "$OUTPUT_FORMAT" ]]; then
		OUTPUT_FORMAT="$MERGED_FORMAT"
	fi

	# Determine output file if not specified
	if [[ -z "$OUTPUT_FILE" ]]; then
		OUTPUT_FILE=$(merged_output_name "$OUTPUT_FORMAT")
	fi

	# Convert to output format if different from merged format
	if [[ "$MERGED_FORMAT" != "$OUTPUT_FORMAT" ]]; then
		# Fail by name when no converter exists; a runtime failure of an
		# implemented converter (missing tool) stays exit 1 below
		require_conversion_supported "$MERGED_FORMAT" "$OUTPUT_FORMAT"

		log_info "Converting from $MERGED_FORMAT to $OUTPUT_FORMAT..."
		# Convert into a scratch file and move it into place only on success,
		# so a failed conversion never leaves a partial or stale OUTPUT_FILE
		temp_converted="${temp_merged}.converted"
		if convert_coverage "$temp_merged" "$temp_converted" "$MERGED_FORMAT" "$OUTPUT_FORMAT"; then
			mv "$temp_converted" "$OUTPUT_FILE"
			log_info "Conversion successful"
		else
			rm -f "$temp_converted"
			log_error "Conversion failed: cannot convert from $MERGED_FORMAT to $OUTPUT_FORMAT"
			log_error "Merged file was: $temp_merged"
			log_error "This would produce an incorrectly labeled output file"
			exit 1
		fi
	else
		cp "$temp_merged" "$OUTPUT_FILE"
	fi

	if [[ -f "$OUTPUT_FILE" ]]; then
		log_success "Merged coverage written to: $OUTPUT_FILE"
		set_github_output "merged-coverage-file" "$OUTPUT_FILE"
		set_github_output "merged-format" "$OUTPUT_FORMAT"

		# Extract coverage percentage
		coverage_percent=$(extract_coverage_percent "$OUTPUT_FILE")
		set_github_output "coverage-percent" "$coverage_percent"
		log_info "Combined coverage: ${coverage_percent}%"

		# Valid LCOV with no measured lines is 0% by arithmetic; say so rather
		# than let it pass as a quiet green (#1078)
		if [[ "$OUTPUT_FORMAT" == "lcov" ]]; then
			lines_found=$(_lcov_sum_totals "$OUTPUT_FILE" LF)
			if [[ "$lines_found" -eq 0 ]]; then
				echo "::warning::merged LCOV has no lines found (LF total 0); coverage is 0%"
				log_warn "No instrumented lines in: ${existing_files[*]}"
			fi
		fi
	else
		log_error "Failed to create merged coverage file"
		exit 1
	fi
	;;

convert)
	: "${INPUT_FILE:=}"
	: "${INPUT_FORMAT:=auto}"
	: "${OUTPUT_FORMAT:=lcov}"
	: "${OUTPUT_FILE:=}"

	if [[ -z "$INPUT_FILE" ]] || [[ ! -f "$INPUT_FILE" ]]; then
		log_error "Input file not found: $INPUT_FILE"
		exit 1
	fi

	# Determine output file if not specified
	if [[ -z "$OUTPUT_FILE" ]]; then
		case "$OUTPUT_FORMAT" in
		json) OUTPUT_FILE="coverage.json" ;;
		lcov) OUTPUT_FILE="coverage.lcov" ;;
		cobertura) OUTPUT_FILE="coverage.xml" ;;
		*) OUTPUT_FILE="coverage.out" ;;
		esac
	fi

	if [[ "$INPUT_FORMAT" == "auto" ]]; then
		INPUT_FORMAT=$(detect_coverage_format "$INPUT_FILE") || {
			log_error "Cannot detect coverage format: $INPUT_FILE"
			exit 1
		}
	fi
	require_conversion_supported "$INPUT_FORMAT" "$OUTPUT_FORMAT"

	log_info "Converting $INPUT_FILE to $OUTPUT_FORMAT..."

	if convert_coverage "$INPUT_FILE" "$OUTPUT_FILE" "$INPUT_FORMAT" "$OUTPUT_FORMAT"; then
		log_success "Converted coverage written to: $OUTPUT_FILE"
		set_github_output "converted-file" "$OUTPUT_FILE"
	else
		log_error "Failed to convert coverage"
		exit 1
	fi
	;;

summary)
	: "${COVERAGE_FILE:=}"
	: "${COVERAGE_PERCENT:=}"

	add_github_summary "## Coverage Summary"
	add_github_summary ""

	# Initialize coverage variables before extraction
	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	COVERAGE_STATEMENTS=""

	if [[ -n "$COVERAGE_FILE" ]] && [[ -f "$COVERAGE_FILE" ]]; then
		# Extract detailed metrics
		extract_coverage_details "$COVERAGE_FILE"

		add_github_summary "| Metric | Coverage |"
		add_github_summary "|--------|----------|"

		# A metric the file does not measure renders as n/a, not 0% (#1078).
		# Lines is always measured, so a 0 there is a real 0%; for the other
		# rows a bare "0" is extract_coverage_details' initial value for a
		# metric the format never set, and is hidden as before.
		add_summary_metric() {
			local label="$1" value="$2" show_zero="${3:-false}"
			if [[ "$value" == "${COVERAGE_NOT_MEASURED:-n/a}" ]]; then
				add_github_summary "| $label | ${COVERAGE_NOT_MEASURED:-n/a} |"
			elif [[ -n "$value" ]] && { [[ "$value" != "0" ]] || [[ "$show_zero" == "true" ]]; }; then
				add_github_summary "| $label | ${value}% |"
			fi
		}
		add_summary_metric "Lines" "$COVERAGE_LINES" true
		add_summary_metric "Branches" "$COVERAGE_BRANCHES"
		add_summary_metric "Functions" "$COVERAGE_FUNCTIONS"
		add_summary_metric "Statements" "$COVERAGE_STATEMENTS"

		set_github_output "lines-coverage" "$COVERAGE_LINES"
		set_github_output "branches-coverage" "$COVERAGE_BRANCHES"
		set_github_output "functions-coverage" "$COVERAGE_FUNCTIONS"
	elif [[ -n "$COVERAGE_PERCENT" ]]; then
		add_github_summary "**Overall Coverage:** ${COVERAGE_PERCENT}%"
	else
		add_github_summary "> No coverage data available."
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
