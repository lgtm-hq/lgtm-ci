#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Coverage extraction utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/extract.sh"
#   percent=$(extract_coverage_percent "coverage.json")

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_COVERAGE_EXTRACT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_COVERAGE_EXTRACT_LOADED=1

# Get directory of this script for sourcing dependencies
_LGTM_CI_TESTING_COV_EXTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"

# Source detect.sh for format detection (required dependency)
# shellcheck source=../detect.sh
if [[ -f "$_LGTM_CI_TESTING_COV_EXTRACT_DIR/detect.sh" ]]; then
	source "$_LGTM_CI_TESTING_COV_EXTRACT_DIR/detect.sh"
else
	echo "Error: Required dependency detect.sh not found at $_LGTM_CI_TESTING_COV_EXTRACT_DIR/detect.sh" >&2
	return 1
fi

# Value extract_coverage_details assigns to a metric the coverage file does not
# measure (for example branches in line-only LCOV). Consumers must treat it as
# "unknown", not as 0%.
readonly COVERAGE_NOT_MEASURED="n/a"

# Internal: sum LCOV record totals in one pass.
# Usage: _lcov_sum_totals "coverage.info" LF LH [BRF BRH ...]
# Output: one line with a sum per requested key, in order; a key with no
# records sums to 0, so the output always has one number per key.
_lcov_sum_totals() {
	local file="${1:-}"
	shift
	awk -F: -v keys="$*" '
		BEGIN { n = split(keys, key, " "); for (i = 1; i <= n; i++) sum[key[i]] = 0 }
		($1 in sum) { sum[$1] += $2 + 0 }
		END {
			for (i = 1; i <= n; i++) printf "%s%d", (i > 1 ? " " : ""), sum[key[i]]
			printf "\n"
		}
	' "$file"
}

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
		read -r lines_found lines_hit < <(_lcov_sum_totals "$file" LF LH)
		if [[ "$lines_found" -gt 0 ]]; then
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
		# One awk pass sums every total; a record type that is absent (line-only
		# LCOV omits BRF/BRH/FNF/FNH) sums to 0 instead of killing a `set -e`
		# caller through a grep that matched nothing (#1078).
		local lf lh bf bh ff fh
		read -r lf lh bf bh ff fh < <(_lcov_sum_totals "$file" LF LH BRF BRH FNF FNH)

		# Lines
		if [[ "$lf" -gt 0 ]]; then
			COVERAGE_LINES=$(echo "$lh $lf" | awk '{printf "%.2f", ($1 / $2) * 100}')
		fi

		# Branches and functions: a zero total means the producer did not
		# measure the metric, which is not the same as measuring 0% of it.
		if [[ "$bf" -gt 0 ]]; then
			COVERAGE_BRANCHES=$(echo "$bh $bf" | awk '{printf "%.2f", ($1 / $2) * 100}')
		else
			COVERAGE_BRANCHES="${COVERAGE_NOT_MEASURED:-n/a}"
		fi

		if [[ "$ff" -gt 0 ]]; then
			COVERAGE_FUNCTIONS=$(echo "$fh $ff" | awk '{printf "%.2f", ($1 / $2) * 100}')
		else
			COVERAGE_FUNCTIONS="${COVERAGE_NOT_MEASURED:-n/a}"
		fi

		# LCOV does not report statements separately; line coverage is the
		# closest compatible metric for consumers that expect statements.
		COVERAGE_STATEMENTS=$COVERAGE_LINES
		;;
	esac

	return 0
}

# Export functions
export -f _lcov_sum_totals extract_coverage_percent extract_coverage_details
