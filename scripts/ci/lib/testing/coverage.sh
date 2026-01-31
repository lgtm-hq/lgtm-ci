#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Coverage extraction and merging utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/coverage.sh"
#   percent=$(extract_coverage_percent "coverage.json")

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_COVERAGE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_COVERAGE_LOADED=1

# Get directory of this script for sourcing dependencies
_LGTM_CI_TESTING_COV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source detect.sh for format detection
# shellcheck source=./detect.sh
[[ -f "$_LGTM_CI_TESTING_COV_DIR/detect.sh" ]] && source "$_LGTM_CI_TESTING_COV_DIR/detect.sh"

# =============================================================================
# Coverage extraction
# =============================================================================

# Extract coverage percentage from various coverage file formats
# Usage: extract_coverage_percent "coverage.json"
# Output: coverage percentage as a number (e.g., "85.5")
extract_coverage_percent() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		echo "0"
		return 1
	fi

	local format
	format=$(detect_coverage_format "$file")

	case "$format" in
	coverage-py)
		# Python coverage.py JSON format
		jq -r '.totals.percent_covered // 0' "$file" 2>/dev/null || echo "0"
		;;
	istanbul)
		# Istanbul/NYC JSON format (coverage-summary.json)
		if jq -e '.total.lines.pct' "$file" &>/dev/null; then
			jq -r '.total.lines.pct // 0' "$file" 2>/dev/null || echo "0"
		else
			# Full istanbul format - calculate from all files
			jq -r '[to_entries[] | select(.key != "total") | .value.lines.pct // 0] | add / length // 0' "$file" 2>/dev/null || echo "0"
		fi
		;;
	cobertura)
		# Cobertura XML format - extract line-rate attribute and convert to percentage
		local line_rate
		line_rate=$(grep -oP 'line-rate="\K[0-9.]+' "$file" | head -1)
		if [[ -n "$line_rate" ]]; then
			echo "$line_rate" | awk '{printf "%.2f", $1 * 100}'
		else
			echo "0"
		fi
		;;
	lcov)
		# LCOV format - calculate from LF (lines found) and LH (lines hit)
		local lines_found lines_hit
		lines_found=$(grep -E '^LF:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		lines_hit=$(grep -E '^LH:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		if [[ -n "$lines_found" ]] && [[ "$lines_found" -gt 0 ]]; then
			echo "$lines_hit $lines_found" | awk '{printf "%.2f", ($1 / $2) * 100}'
		else
			echo "0"
		fi
		;;
	json)
		# Try common JSON formats
		if jq -e '.totals.percent_covered' "$file" &>/dev/null; then
			jq -r '.totals.percent_covered // 0' "$file"
		elif jq -e '.total.lines.pct' "$file" &>/dev/null; then
			jq -r '.total.lines.pct // 0' "$file"
		elif jq -e '.coverage' "$file" &>/dev/null; then
			jq -r '.coverage // 0' "$file"
		else
			echo "0"
		fi
		;;
	*)
		echo "0"
		return 1
		;;
	esac
}

# Extract detailed coverage metrics from a coverage file
# Usage: extract_coverage_details "coverage.json"
# Sets: COVERAGE_LINES, COVERAGE_BRANCHES, COVERAGE_FUNCTIONS, COVERAGE_STATEMENTS
extract_coverage_details() {
	local file="${1:-}"

	COVERAGE_LINES="0"
	COVERAGE_BRANCHES="0"
	COVERAGE_FUNCTIONS="0"
	COVERAGE_STATEMENTS="0"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	local format
	format=$(detect_coverage_format "$file")

	case "$format" in
	coverage-py)
		COVERAGE_LINES=$(jq -r '.totals.percent_covered // 0' "$file" 2>/dev/null || echo "0")
		COVERAGE_BRANCHES=$(jq -r '.totals.percent_covered_branches // 0' "$file" 2>/dev/null || echo "0")
		;;
	istanbul)
		COVERAGE_LINES=$(jq -r '.total.lines.pct // 0' "$file" 2>/dev/null || echo "0")
		COVERAGE_BRANCHES=$(jq -r '.total.branches.pct // 0' "$file" 2>/dev/null || echo "0")
		COVERAGE_FUNCTIONS=$(jq -r '.total.functions.pct // 0' "$file" 2>/dev/null || echo "0")
		COVERAGE_STATEMENTS=$(jq -r '.total.statements.pct // 0' "$file" 2>/dev/null || echo "0")
		;;
	cobertura)
		local line_rate branch_rate
		line_rate=$(grep -oP 'line-rate="\K[0-9.]+' "$file" | head -1)
		branch_rate=$(grep -oP 'branch-rate="\K[0-9.]+' "$file" | head -1)
		if [[ -n "$line_rate" ]]; then
			COVERAGE_LINES=$(echo "$line_rate" | awk '{printf "%.2f", $1 * 100}')
		fi
		if [[ -n "$branch_rate" ]]; then
			COVERAGE_BRANCHES=$(echo "$branch_rate" | awk '{printf "%.2f", $1 * 100}')
		fi
		;;
	lcov)
		# Lines
		local lf lh
		lf=$(grep -E '^LF:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		lh=$(grep -E '^LH:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		if [[ -n "$lf" ]] && [[ "$lf" -gt 0 ]]; then
			COVERAGE_LINES=$(echo "$lh $lf" | awk '{printf "%.2f", ($1 / $2) * 100}')
		fi

		# Branches
		local bf bh
		bf=$(grep -E '^BRF:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		bh=$(grep -E '^BRH:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		if [[ -n "$bf" ]] && [[ "$bf" -gt 0 ]]; then
			COVERAGE_BRANCHES=$(echo "$bh $bf" | awk '{printf "%.2f", ($1 / $2) * 100}')
		fi

		# Functions
		local ff fh
		ff=$(grep -E '^FNF:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		fh=$(grep -E '^FNH:' "$file" | cut -d: -f2 | awk '{sum+=$1} END {print sum}')
		if [[ -n "$ff" ]] && [[ "$ff" -gt 0 ]]; then
			COVERAGE_FUNCTIONS=$(echo "$fh $ff" | awk '{printf "%.2f", ($1 / $2) * 100}')
		fi
		;;
	esac

	return 0
}

# =============================================================================
# Coverage merging
# =============================================================================

# Merge multiple LCOV files into one
# Usage: merge_lcov_files "output.lcov" "file1.lcov" "file2.lcov" ...
merge_lcov_files() {
	local output="${1:-}"
	shift
	local files=("$@")

	if [[ -z "$output" ]] || [[ ${#files[@]} -eq 0 ]]; then
		return 1
	fi

	# Check if lcov is available
	if command -v lcov &>/dev/null; then
		local lcov_args=()
		for file in "${files[@]}"; do
			if [[ -f "$file" ]]; then
				lcov_args+=("-a" "$file")
			fi
		done
		lcov "${lcov_args[@]}" -o "$output" 2>/dev/null
	else
		# Simple concatenation as fallback (not ideal but works for basic cases)
		true >"$output"
		for file in "${files[@]}"; do
			if [[ -f "$file" ]]; then
				cat "$file" >>"$output"
			fi
		done
	fi
}

# Merge multiple istanbul JSON coverage files
# Usage: merge_istanbul_files "output.json" "file1.json" "file2.json" ...
merge_istanbul_files() {
	local output="${1:-}"
	shift
	local files=("$@")

	if [[ -z "$output" ]] || [[ ${#files[@]} -eq 0 ]]; then
		return 1
	fi

	# Check if nyc is available
	if command -v nyc &>/dev/null; then
		local temp_dir
		temp_dir=$(mktemp -d)
		local i=0
		for file in "${files[@]}"; do
			if [[ -f "$file" ]]; then
				cp "$file" "$temp_dir/coverage-$i.json"
				((i++))
			fi
		done
		nyc merge "$temp_dir" "$output" 2>/dev/null
		rm -rf "$temp_dir"
	else
		# Manual merge using jq
		if [[ ${#files[@]} -eq 1 ]]; then
			cp "${files[0]}" "$output"
		else
			# Start with first file
			local merged
			merged=$(cat "${files[0]}")
			for ((i = 1; i < ${#files[@]}; i++)); do
				if [[ -f "${files[$i]}" ]]; then
					merged=$(echo "$merged" | jq -s '.[0] * .[1]' - "${files[$i]}")
				fi
			done
			echo "$merged" >"$output"
		fi
	fi
}

# Convert coverage from one format to another
# Usage: convert_coverage "input.xml" "output.lcov" "cobertura" "lcov"
convert_coverage() {
	local input="${1:-}"
	local output="${2:-}"
	local from_format="${3:-auto}"
	local to_format="${4:-lcov}"

	if [[ ! -f "$input" ]]; then
		return 1
	fi

	if [[ "$from_format" == "auto" ]]; then
		from_format=$(detect_coverage_format "$input")
	fi

	# Conversion strategies based on available tools
	case "${from_format}->${to_format}" in
	"cobertura->lcov")
		if command -v pycobertura &>/dev/null; then
			pycobertura show --format lcov "$input" >"$output"
		else
			# Manual conversion (basic)
			_convert_cobertura_to_lcov "$input" "$output"
		fi
		;;
	"istanbul->lcov")
		if command -v nyc &>/dev/null; then
			nyc report --reporter=lcov --temp-dir="$(dirname "$input")" >"$output" 2>/dev/null
		else
			_convert_istanbul_to_lcov "$input" "$output"
		fi
		;;
	"coverage-py->lcov")
		if command -v coverage &>/dev/null; then
			coverage lcov -o "$output" 2>/dev/null
		else
			# coverage.py JSON doesn't easily convert without the tool
			return 1
		fi
		;;
	"lcov->cobertura")
		if command -v lcov_cobertura &>/dev/null; then
			lcov_cobertura "$input" -o "$output"
		else
			return 1
		fi
		;;
	*)
		# Same format or unsupported conversion
		if [[ "$from_format" == "$to_format" ]]; then
			cp "$input" "$output"
		else
			return 1
		fi
		;;
	esac
}

# Internal: Convert Cobertura XML to LCOV format
_convert_cobertura_to_lcov() {
	local input="${1:-}"
	local output="${2:-}"

	# Basic conversion using grep/awk
	{
		echo "TN:"
		# Extract source files and line coverage
		grep -oP '<class[^>]+filename="\K[^"]+' "$input" | while read -r filename; do
			echo "SF:$filename"
			# This is a simplified conversion - full conversion would need XML parsing
			echo "end_of_record"
		done
	} >"$output"
}

# Internal: Convert Istanbul JSON to LCOV format
_convert_istanbul_to_lcov() {
	local input="${1:-}"
	local output="${2:-}"

	# Use jq for basic conversion
	jq -r '
		to_entries[] |
		select(.key != "total") |
		"TN:\nSF:\(.value.path // .key)\n" +
		(.value.statementMap | to_entries | map("DA:\(.value.start.line),\(if .key | tonumber | . as $k | $input.s[$k] then 1 else 0 end)") | join("\n")) +
		"\nend_of_record"
	' "$input" >"$output" 2>/dev/null || {
		# Fallback: just create a minimal LCOV
		echo "TN:" >"$output"
	}
}

# =============================================================================
# Coverage threshold checking
# =============================================================================

# Check if coverage meets a threshold
# Usage: check_coverage_threshold 85.5 80
# Returns: 0 if coverage >= threshold, 1 otherwise
check_coverage_threshold() {
	local coverage="${1:-0}"
	local threshold="${2:-0}"

	# Use awk for floating point comparison
	awk -v cov="$coverage" -v thresh="$threshold" 'BEGIN { exit (cov >= thresh ? 0 : 1) }'
}

# Get coverage delta between two values
# Usage: get_coverage_delta 85.5 80.0
# Output: +5.5 or -5.5
get_coverage_delta() {
	local current="${1:-0}"
	local previous="${2:-0}"

	awk -v cur="$current" -v prev="$previous" 'BEGIN {
		delta = cur - prev
		if (delta >= 0) {
			printf "+%.2f", delta
		} else {
			printf "%.2f", delta
		}
	}'
}

# =============================================================================
# Export functions
# =============================================================================
export -f extract_coverage_percent extract_coverage_details
export -f merge_lcov_files merge_istanbul_files convert_coverage
export -f check_coverage_threshold get_coverage_delta
