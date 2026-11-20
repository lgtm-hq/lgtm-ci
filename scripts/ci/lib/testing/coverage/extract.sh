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

# Value extract_coverage_details assigns to a metric the coverage file holds
# in a form that is not a number (#1692): an LCOV count such as BRF:oops or
# LH:1junk, a Cobertura rate such as line-rate="1..0", a hit count above its
# total, or a line total the format requires but the file lacks. Consumers
# must treat it as unreadable: never 0, never n/a, never a pass.
readonly COVERAGE_INVALID="invalid"

# Internal: read LCOV record totals, checking every record first (#1692).
# Usage: _lcov_read_totals "coverage.info" LF LH [BRF BRH ...]
# Output: one word per requested key, in order: the sum of its records,
# "absent" when the file has none, or "invalid" when any record's value is
# not a whole number of at most nine digits (a trailing CR is allowed).
_lcov_read_totals() {
	local file="${1:-}"
	shift
	awk -F: -v keys="$*" '
		BEGIN { n = split(keys, key, " "); for (i = 1; i <= n; i++) seen[key[i]] = 0 }
		($1 in seen) {
			value = substr($0, length($1) + 2)
			sub(/\r$/, "", value)
			seen[$1]++
			if (value !~ /^[0-9]+$/ || length(value) > 9) bad[$1] = 1
			else sum[$1] += value
		}
		END {
			for (i = 1; i <= n; i++) {
				k = key[i]
				word = (k in bad) ? "invalid" : (seen[k] ? sprintf("%d", sum[k]) : "absent")
				printf "%s%s", (i > 1 ? " " : ""), word
			}
			printf "\n"
		}
	' "$file"
}

# Internal: one LCOV percentage from its found and hit totals.
# Usage: _lcov_percent FOUND HIT IF_ABSENT IF_ZERO
# A pair with an invalid total, a hit total without a found one (or the
# reverse), or more hits than found is invalid. With neither total in the
# file it prints IF_ABSENT, and with a found total of 0 it prints IF_ZERO.
_lcov_percent() {
	local found="$1" hit="$2" if_absent="$3" if_zero="$4"
	if [[ "$found" == absent && "$hit" == absent ]]; then
		echo "$if_absent"
	elif [[ ! "$found" =~ ^[0-9]+$ || ! "$hit" =~ ^[0-9]+$ ]] || ((hit > found)); then
		echo "$COVERAGE_INVALID"
	elif ((found == 0)); then
		echo "$if_zero"
	else
		awk -v h="$hit" -v f="$found" 'BEGIN { printf "%.2f", (h / f) * 100 }'
	fi
}

# Internal: an attribute of a Cobertura report's root <coverage> element.
# Usage: _cobertura_root_attribute "coverage.xml" line-rate
# Output: the attribute's raw value, or nothing when the element or the
# attribute is absent. Attributes of nested elements are never read.
_cobertura_root_attribute() {
	local file="${1:-}" name="${2:-}"
	awk -v RS='>' -v name="$name" '
		/<coverage[ \t\r\n]/ {
			tag = substr($0, index($0, "<coverage"))
			gsub(/[\t\r\n]/, " ", tag)
			if (match(tag, " " name "=\"[^\"]*\"")) {
				value = substr(tag, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
				print value
			}
			exit
		}
	' "$file"
}

# Internal: a Cobertura rate as a percentage with two decimals.
# Usage: _cobertura_percent RATE
# A rate that is not a plain decimal from 0 to 1 (coverage.py may write
# 1.234e-05) prints COVERAGE_INVALID.
_cobertura_percent() {
	local rate="$1"
	if [[ "$rate" =~ ^[0-9]{1,6}(\.[0-9]{1,20})?([eE][-+]?[0-9]{1,3})?$ ]] &&
		awk -v r="$rate" 'BEGIN { exit !(r + 0 <= 1) }'; then
		awk -v r="$rate" 'BEGIN { printf "%.2f", r * 100 }'
	else
		echo "$COVERAGE_INVALID"
	fi
}

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
#       (for LCOV and Cobertura each is a percentage, COVERAGE_NOT_MEASURED
#       or COVERAGE_INVALID)
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
		# The rates are attributes of the root <coverage> element, checked as
		# written before any arithmetic (#1692): line-rate="1..0" is invalid,
		# not 100%. The format requires line-rate, so a file without it is
		# invalid rather than 0%; branch-rate keeps the old 0 when absent.
		local line_rate branch_rate
		line_rate=$(_cobertura_root_attribute "$file" line-rate)
		branch_rate=$(_cobertura_root_attribute "$file" branch-rate)
		COVERAGE_LINES=$(_cobertura_percent "$line_rate")
		if [[ -n "$branch_rate" ]]; then
			COVERAGE_BRANCHES=$(_cobertura_percent "$branch_rate")
		fi
		;;
	lcov)
		# One awk pass reads every total and checks each record first (#1692):
		# BRF:oops or LH:1junk is invalid, never 0 or a sum of what parsed.
		# A record type that is absent (line-only LCOV omits BRF/BRH/FNF/FNH)
		# is "absent" instead of killing a `set -e` caller through a grep that
		# matched nothing (#1078).
		local lf lh bf bh ff fh
		read -r lf lh bf bh ff fh < <(_lcov_read_totals "$file" LF LH BRF BRH FNF FNH)

		# Lines are required: no LF/LH records at all is invalid; LF:0 is a
		# real report of no instrumented lines and stays 0.
		COVERAGE_LINES=$(_lcov_percent "$lf" "$lh" "$COVERAGE_INVALID" 0)

		# Branches and functions: an absent or zero total means the producer
		# did not measure the metric, which is not the same as measuring 0%.
		COVERAGE_BRANCHES=$(_lcov_percent "$bf" "$bh" "$COVERAGE_NOT_MEASURED" "$COVERAGE_NOT_MEASURED")
		COVERAGE_FUNCTIONS=$(_lcov_percent "$ff" "$fh" "$COVERAGE_NOT_MEASURED" "$COVERAGE_NOT_MEASURED")

		# LCOV does not report statements separately; line coverage is the
		# closest compatible metric for consumers that expect statements.
		COVERAGE_STATEMENTS=$COVERAGE_LINES
		;;
	esac

	return 0
}

# Export functions
export -f _lcov_sum_totals _lcov_read_totals _lcov_percent _cobertura_root_attribute _cobertura_percent
export -f extract_coverage_percent extract_coverage_details
