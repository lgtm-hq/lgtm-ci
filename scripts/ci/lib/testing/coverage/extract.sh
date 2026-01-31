#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Coverage extraction utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/extract.sh"
#   percent=$(extract_coverage_percent "coverage.json")

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_COVERAGE_EXTRACT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_COVERAGE_EXTRACT_LOADED=1

# Get directory of this script for sourcing dependencies
_LGTM_CI_TESTING_COV_EXTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source detect.sh for format detection
# shellcheck source=../detect.sh
[[ -f "$_LGTM_CI_TESTING_COV_EXTRACT_DIR/detect.sh" ]] && source "$_LGTM_CI_TESTING_COV_EXTRACT_DIR/detect.sh"

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
		elif jq -e '[to_entries[] | select(.key != "total") | .value.lines] | length > 0' "$file" &>/dev/null; then
			# Full istanbul format with per-file coverage - calculate weighted average
			jq -r '
				[to_entries[] | select(.key != "total") | .value.lines] as $lines
				| ([$lines[].covered] | add) as $covered
				| ([$lines[].total] | add) as $total
				| if ($total // 0) > 0 then ($covered / $total * 100) else 0 end
			' "$file" 2>/dev/null || echo "0"
		else
			# coverage-final.json format without .lines.pct - cannot extract coverage
			echo "Error: Istanbul coverage file does not contain .total.lines.pct or per-file .lines.pct" >&2
			echo "This appears to be coverage-final.json. Please use coverage-summary.json instead." >&2
			echo "Generate with: nyc report --reporter=json-summary" >&2
			echo "0"
			return 1
		fi
		;;
	cobertura)
		# Cobertura XML format - extract line-rate attribute and convert to percentage
		local line_rate
		line_rate=$(sed -n 's/.*line-rate="\([0-9.]*\)".*/\1/p' "$file" | head -1)
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
		# Check for coverage-summary.json format with .total
		if jq -e '.total.lines.pct' "$file" &>/dev/null; then
			COVERAGE_LINES=$(jq -r '.total.lines.pct // 0' "$file" 2>/dev/null || echo "0")
			COVERAGE_BRANCHES=$(jq -r '.total.branches.pct // 0' "$file" 2>/dev/null || echo "0")
			COVERAGE_FUNCTIONS=$(jq -r '.total.functions.pct // 0' "$file" 2>/dev/null || echo "0")
			COVERAGE_STATEMENTS=$(jq -r '.total.statements.pct // 0' "$file" 2>/dev/null || echo "0")
		elif jq -e '[to_entries[] | select(.key != "total") | .value.lines] | length > 0' "$file" &>/dev/null; then
			# Full istanbul format with per-file coverage - calculate weighted averages
			COVERAGE_LINES=$(jq -r '
				[to_entries[] | select(.key != "total") | .value.lines] as $data
				| ([$data[].covered] | add) as $covered
				| ([$data[].total] | add) as $total
				| if ($total // 0) > 0 then ($covered / $total * 100) else 0 end
			' "$file" 2>/dev/null || echo "0")
			COVERAGE_BRANCHES=$(jq -r '
				[to_entries[] | select(.key != "total") | .value.branches] as $data
				| ([$data[].covered] | add) as $covered
				| ([$data[].total] | add) as $total
				| if ($total // 0) > 0 then ($covered / $total * 100) else 0 end
			' "$file" 2>/dev/null || echo "0")
			COVERAGE_FUNCTIONS=$(jq -r '
				[to_entries[] | select(.key != "total") | .value.functions] as $data
				| ([$data[].covered] | add) as $covered
				| ([$data[].total] | add) as $total
				| if ($total // 0) > 0 then ($covered / $total * 100) else 0 end
			' "$file" 2>/dev/null || echo "0")
			COVERAGE_STATEMENTS=$(jq -r '
				[to_entries[] | select(.key != "total") | .value.statements] as $data
				| ([$data[].covered] | add) as $covered
				| ([$data[].total] | add) as $total
				| if ($total // 0) > 0 then ($covered / $total * 100) else 0 end
			' "$file" 2>/dev/null || echo "0")
		else
			# coverage-final.json format - cannot extract detailed coverage
			echo "Error: Istanbul coverage file does not contain coverage percentages" >&2
			echo "This appears to be coverage-final.json. Please use coverage-summary.json instead." >&2
			echo "Generate with: nyc report --reporter=json-summary" >&2
			return 1
		fi
		;;
	cobertura)
		local line_rate branch_rate
		line_rate=$(sed -n 's/.*line-rate="\([0-9.]*\)".*/\1/p' "$file" | head -1)
		branch_rate=$(sed -n 's/.*branch-rate="\([0-9.]*\)".*/\1/p' "$file" | head -1)
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

# Export functions
export -f extract_coverage_percent extract_coverage_details
