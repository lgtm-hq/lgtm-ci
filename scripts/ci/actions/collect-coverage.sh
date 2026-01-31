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
	files=()
	if [[ "$COVERAGE_FILES" == *","* ]]; then
		# Comma-separated
		IFS=',' read -ra files <<<"$COVERAGE_FILES"
	else
		# Newline-separated
		mapfile -t files <<<"$COVERAGE_FILES"
	fi

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

	# Determine input format from files if auto
	if [[ "$INPUT_FORMAT" == "auto" ]]; then
		INPUT_FORMAT=$(detect_coverage_format "${existing_files[0]}")

		# Validate all files have the same format
		for file in "${existing_files[@]:1}"; do
			file_format=$(detect_coverage_format "$file")
			if [[ "$file_format" != "$INPUT_FORMAT" ]]; then
				log_error "Mixed coverage formats detected:"
				log_error "  - ${existing_files[0]}: $INPUT_FORMAT"
				log_error "  - $file: $file_format"
				log_error "Please specify INPUT_FORMAT explicitly or supply consistent files"
				exit 1
			fi
		done
	fi

	# Create temp file for merging in input format
	temp_merged=$(mktemp)
	trap 'rm -f "$temp_merged"' EXIT

	# Merge based on input format
	case "$INPUT_FORMAT" in
	lcov)
		merge_lcov_files "$temp_merged" "${existing_files[@]}"
		;;
	istanbul | json)
		merge_istanbul_files "$temp_merged" "${existing_files[@]}"
		;;
	coverage-py | cobertura)
		# Check if files are .coverage binary data files (for coverage combine)
		all_binary=true
		for file in "${existing_files[@]}"; do
			basename_file=$(basename "$file")
			# .coverage files are binary data, not JSON/XML
			if [[ ! "$basename_file" =~ ^\.coverage ]] && [[ ! "$file" =~ \.coverage$ ]]; then
				all_binary=false
				break
			fi
		done

		if [[ ${#existing_files[@]} -eq 1 ]]; then
			cp "${existing_files[0]}" "$temp_merged"
		elif [[ "$all_binary" == "true" ]] && command -v coverage &>/dev/null; then
			# Only use coverage combine for actual .coverage binary files
			coverage combine "${existing_files[@]}"
			case "$INPUT_FORMAT" in
			coverage-py) coverage json -o "$temp_merged" ;;
			cobertura) coverage xml -o "$temp_merged" ;;
			*) coverage json -o "$temp_merged" ;;
			esac
		else
			# Files are XML/JSON reports, not binary - can't use coverage combine
			log_warn "Files are not .coverage binary data files, cannot use coverage combine"
			log_warn "Rejected files: ${existing_files[*]}"
			log_warn "Using first file as fallback"
			cp "${existing_files[0]}" "$temp_merged"
		fi
		;;
	*)
		log_error "Unsupported input format for merging: $INPUT_FORMAT"
		exit 1
		;;
	esac

	# Convert to output format if different from input format
	if [[ "$INPUT_FORMAT" != "$OUTPUT_FORMAT" ]]; then
		log_info "Converting from $INPUT_FORMAT to $OUTPUT_FORMAT..."
		if convert_coverage "$temp_merged" "$OUTPUT_FILE" "$INPUT_FORMAT" "$OUTPUT_FORMAT"; then
			log_info "Conversion successful"
		else
			log_error "Conversion failed: cannot convert from $INPUT_FORMAT to $OUTPUT_FORMAT"
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
