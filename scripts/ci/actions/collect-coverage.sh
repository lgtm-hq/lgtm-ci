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
#   OUTPUT_FORMAT - Output format: json, lcov (default: json)
#   MERGE_STRATEGY - How to merge: union, intersection (default: union)
#   OUTPUT_FILE - Output file path (default: merged-coverage.json or merged-coverage.lcov)
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
		format=$(detect_coverage_format "$file")
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
	: "${OUTPUT_FORMAT:=json}"
	: "${OUTPUT_FILE:=}"
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Parse coverage files (comma-separated or newline-separated)
	IFS=$',\n' read -ra files <<<"$COVERAGE_FILES"

	# Filter to existing files
	existing_files=()
	for file in "${files[@]}"; do
		# Trim whitespace
		file="${file#"${file%%[![:space:]]*}"}"
		file="${file%"${file##*[![:space:]]}"}"
		if [[ -n "$file" ]] && [[ -f "$file" ]]; then
			existing_files+=("$file")
		fi
	done

	if [[ ${#existing_files[@]} -eq 0 ]]; then
		log_error "No valid coverage files found"
		exit 1
	fi

	log_info "Merging ${#existing_files[@]} coverage files..."

	# Determine output file if not specified
	if [[ -z "$OUTPUT_FILE" ]]; then
		case "$OUTPUT_FORMAT" in
		json) OUTPUT_FILE="merged-coverage.json" ;;
		lcov) OUTPUT_FILE="merged-coverage.lcov" ;;
		*) OUTPUT_FILE="merged-coverage.json" ;;
		esac
	fi

	# Determine input format from first file if auto
	if [[ "$INPUT_FORMAT" == "auto" ]]; then
		INPUT_FORMAT=$(detect_coverage_format "${existing_files[0]}")
	fi

	# Merge based on format
	case "$INPUT_FORMAT" in
	lcov)
		merge_lcov_files "$OUTPUT_FILE" "${existing_files[@]}"
		;;
	istanbul | json)
		merge_istanbul_files "$OUTPUT_FILE" "${existing_files[@]}"
		;;
	coverage-py | cobertura)
		# For Python coverage, if we need to merge, we can concatenate XMLs
		# or rely on coverage.py combine
		if [[ ${#existing_files[@]} -eq 1 ]]; then
			cp "${existing_files[0]}" "$OUTPUT_FILE"
		else
			# Try to use coverage combine if available
			if command -v coverage &>/dev/null; then
				coverage combine "${existing_files[@]}"
				case "$OUTPUT_FORMAT" in
				json) coverage json -o "$OUTPUT_FILE" ;;
				lcov) coverage lcov -o "$OUTPUT_FILE" ;;
				*) coverage json -o "$OUTPUT_FILE" ;;
				esac
			else
				# Just use the first file as fallback
				cp "${existing_files[0]}" "$OUTPUT_FILE"
				log_warn "Multiple Python coverage files but coverage tool not available"
			fi
		fi
		;;
	*)
		log_error "Unsupported input format for merging: $INPUT_FORMAT"
		exit 1
		;;
	esac

	if [[ -f "$OUTPUT_FILE" ]]; then
		log_success "Merged coverage written to: $OUTPUT_FILE"
		set_github_output "merged-coverage-file" "$OUTPUT_FILE"

		# Extract coverage percentage
		coverage_percent=$(extract_coverage_percent "$OUTPUT_FILE")
		set_github_output "coverage-percent" "$coverage_percent"
		log_info "Combined coverage: ${coverage_percent}%"
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

	if [[ -n "$COVERAGE_FILE" ]] && [[ -f "$COVERAGE_FILE" ]]; then
		# Extract detailed metrics
		extract_coverage_details "$COVERAGE_FILE"

		add_github_summary "| Metric | Coverage |"
		add_github_summary "|--------|----------|"

		if [[ -n "$COVERAGE_LINES" ]] && [[ "$COVERAGE_LINES" != "0" ]]; then
			add_github_summary "| Lines | ${COVERAGE_LINES}% |"
		fi
		if [[ -n "$COVERAGE_BRANCHES" ]] && [[ "$COVERAGE_BRANCHES" != "0" ]]; then
			add_github_summary "| Branches | ${COVERAGE_BRANCHES}% |"
		fi
		if [[ -n "$COVERAGE_FUNCTIONS" ]] && [[ "$COVERAGE_FUNCTIONS" != "0" ]]; then
			add_github_summary "| Functions | ${COVERAGE_FUNCTIONS}% |"
		fi
		if [[ -n "$COVERAGE_STATEMENTS" ]] && [[ "$COVERAGE_STATEMENTS" != "0" ]]; then
			add_github_summary "| Statements | ${COVERAGE_STATEMENTS}% |"
		fi

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
