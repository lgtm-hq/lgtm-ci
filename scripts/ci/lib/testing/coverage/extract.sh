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

# Internal: read LCOV totals record by record, checking each record before it
# is added (#1692).
# Usage: _lcov_read_metrics "coverage.info"
# Output: one line, "LF LH BRF BRH FNF FNH": each metric's pair of sums,
# "absent absent" when no record measures it, or "invalid invalid".
#
# A record runs from SF: to end_of_record. A metric is invalid when any
# record gives one of its totals twice, a total that is not a whole number
# of at most nine digits, a hit total without its found total (or the
# reverse) or more hits than found, or when a record has its data lines
# (DA; BRDA; FN, FNDA, FNL, FNA) but not its totals. Every record needs LF
# and LH: lcov/geninfo, c8/istanbul, cargo-llvm-cov (llvm-cov export) and
# gcov2lcov all write them, LF:0/LH:0 for a file with no lines. A total key
# in the wrong case or with spaces (lf:90, "LF :90"), a total or data line
# outside a record, other text outside a record, a record never closed and
# an end_of_record without its SF: make the metrics they touch invalid
# rather than dropping a record. Other keys inside a record (TN, VER, MC*
# and later additions) are ignored; a CR before the newline and a byte-order
# mark at the start of the file are allowed. DA/BRDA/FN lines are not checked
# against the totals: the totals alone are what every reader sums.
#
# A NUL byte anywhere makes every metric invalid before awk reads the file:
# BWK awk (macOS) ends a line at a NUL, so LH:10<NUL>junk would read as
# LH:10 (#1692 review). The program is POSIX awk (no interval expressions,
# arrays cleared key by key, sums printed with %.0f, never %d, which can
# wrap past 2^31); it was run here with BWK awk 20200816 (macOS) and runs on
# the runner's awk in CI.
_lcov_read_metrics() {
	local file="${1:-}"
	# shellcheck disable=SC2094 # both only read the file: tr strips NULs, cmp compares
	if ! LC_ALL=C tr -d '\000' <"$file" | cmp -s - "$file"; then
		echo "invalid invalid invalid invalid invalid invalid"
		return 0
	fi
	awk -v bom="$(printf '\357\273\277')" '
		function forget(k) { for (k in seen) delete seen[k]; for (k in val) delete val[k]; for (k in has) delete has[k] }
		function close_record(i, found, hit) {
			for (i = 1; i <= 3; i++) {
				found = fkey[i]; hit = hkey[i]
				if ((found in seen) != (hit in seen)) bad[i] = 1
				else if (found in seen) {
					if (val[hit] > val[found]) bad[i] = 1
					else { sum[found] += val[found]; sum[hit] += val[hit]; present[i] = 1 }
				} else if (i == 1 || (i in has)) bad[i] = 1
			}
			forget()
		}
		BEGIN {
			split("LF BRF FNF", fkey, " "); split("LH BRH FNH", hkey, " ")
			for (i = 1; i <= 3; i++) { metric[fkey[i]] = i; metric[hkey[i]] = i }
			data["DA"] = 1; data["BRDA"] = 2; data["FN"] = 3; data["FNDA"] = 3; data["FNL"] = 3; data["FNA"] = 3
			open = 0
		}
		{
			line = $0
			sub(/\r$/, "", line)
			if (NR == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1)
			if (line ~ /^[ \t]*$/) next
			colon = index(line, ":")
			key = colon ? substr(line, 1, colon - 1) : line
			value = colon ? substr(line, colon + 1) : ""
			norm = toupper(key)
			gsub(/[ \t]/, "", norm)
			if (key == "SF") { if (open) { bad[1] = bad[2] = bad[3] = 1; forget() }; open = 1; next }
			if (key == "end_of_record") { if (open) close_record(); else bad[1] = 1; open = 0; next }
			if (key == "TN") next
			if ((norm in metric) && key != norm) { bad[metric[norm]] = 1; next }
			if (key in metric) {
				if (!open || (key in seen) || value !~ /^[0-9]+$/ || length(value) > 9) bad[metric[key]] = 1
				else { seen[key] = 1; val[key] = value + 0 }
				next
			}
			if (key in data) { if (open) has[data[key]] = 1; else bad[data[key]] = 1; next }
			if (!open) bad[1] = 1
		}
		END {
			if (open) bad[1] = bad[2] = bad[3] = 1
			for (i = 1; i <= 3; i++) {
				if (i in bad) pair = "invalid invalid"
				else if (i in present) pair = sprintf("%.0f %.0f", sum[fkey[i]], sum[hkey[i]])
				else pair = "absent absent"
				printf "%s%s", (i > 1 ? " " : ""), pair
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

# Internal: the line and branch rates of a Cobertura report's root element.
# Usage: _cobertura_rates "coverage.xml"
# Output: "LINE BRANCH", each a percentage with two decimals, "absent" or
# "invalid" (cobertura_rates.py: a real XML parse of the document root, which
# must be one <coverage> element; scientific notation such as coverage.py's
# 1.234e-05 is converted, a rate outside 0..1 is invalid). Without a python3
# both rates are invalid: the report cannot be read safely.
_cobertura_rates() {
	local file="${1:-}"
	if ! command -v python3 >/dev/null 2>&1; then
		echo "::warning::No python3 on this runner; the Cobertura report cannot be read" >&2
		echo "$COVERAGE_INVALID $COVERAGE_INVALID"
		return 0
	fi
	python3 -I "${_LGTM_CI_TESTING_COV_EXTRACT_DIR}/cobertura_rates.py" "$file" ||
		echo "$COVERAGE_INVALID $COVERAGE_INVALID"
}

# jq definitions shared with generate-coverage-comment.sh, so the comment
# and every other consumer judge a JSON report the same way (#1692).
#
#   pct_ok    a number from 0 to 100
#   count_ok  a whole number from 0 to 999999999 (jq turns 1e400 into the
#             largest double, which is not one)
#   coverage_py_branches_ok   (input: coverage.py .totals) every branch key
#             the report holds is readable and they agree: counts are
#             counts, percentages are percentages, num_branches and
#             covered_branches come together with covered <= num, and a
#             branch percentage is within 0.5 of covered / num * 100 (room
#             for a rounded display value). A report without branch keys
#             passes: it did not measure branches.
# shellcheck disable=SC2016,SC2089 # a jq program: its quotes are jq's, not shell's
_COVERAGE_JQ_DEFS='
def pct_ok: type == "number" and . >= 0 and . <= 100;
def count_ok: type == "number" and . >= 0 and . == floor and . <= 999999999;
def coverage_py_branches_ok:
	. as $t
	| def present(keys): [keys[] | . as $k | select($t | has($k)) | $t[$k]];
	(present(["num_branches", "covered_branches", "missing_branches", "num_partial_branches"])
		| all(count_ok))
	and (present(["percent_covered_branches", "percent_branches_covered"]) | all(pct_ok))
	and (has("num_branches") == has("covered_branches"))
	and (if has("num_branches") and (.num_branches | count_ok) and (.covered_branches | count_ok)
		then .covered_branches <= .num_branches
			and (if .num_branches > 0
				then (.covered_branches / .num_branches * 100) as $derived
					| present(["percent_covered_branches", "percent_branches_covered"])
					| all((. - $derived) | (if . < 0 then -. else . end) <= 0.5)
				else true end)
		else true end);
'

# Internal: a JSON report's percentage, or COVERAGE_INVALID when it is not a
# number from 0 to 100 (absent, null, a string, or the file is not JSON).
# Usage: _json_percent "coverage.json" JQ_PATH
_json_percent() {
	jq -r "${_COVERAGE_JQ_DEFS} $2"' | if pct_ok then . else "invalid" end' \
		"$1" 2>/dev/null || echo "$COVERAGE_INVALID"
}

# Internal: the branch percentage extract_coverage_details gives a coverage.py
# JSON report: COVERAGE_INVALID when any branch key is unreadable or they
# disagree, else percent_covered_branches, else 0 (not measured, as before).
# Usage: _coverage_py_branches "coverage.json"
_coverage_py_branches() {
	_json_percent "$1" '.totals | if coverage_py_branches_ok | not then "invalid"
		elif has("percent_covered_branches") then .percent_covered_branches else 0 end'
}

# jq: the weighted percentage of a per-file istanbul metric (lines, branches,
# functions or statements), or "invalid" when any file that has the metric
# gives a covered and total that are not whole numbers with covered <= total
# (#1692). A file without the metric is skipped, as before; no total => 0.
# shellcheck disable=SC2016,SC2089 # a jq program: its quotes are jq's, not shell's
_ISTANBUL_WEIGHTED='
def weighted(metric):
	[to_entries[] | select(.key != "total") | .value | select(type != "object" or has(metric))
		| if type == "object" then .[metric] else . end] as $data
	| if ($data | all(type == "object"
		and ([.covered, .total] | all(type == "number" and . >= 0 and . == floor))
		and .covered <= .total))
	then ([$data[].covered] | add) as $covered
		| ([$data[].total] | add) as $total
		| if ($total // 0) > 0 then ($covered / $total * 100) else 0 end
	else "invalid" end;
'

# Extract coverage percentage from various coverage file formats
# Usage: extract_coverage_percent "coverage.json"
# Output: the line coverage percentage (e.g. "85.5"); exit status 0.
#         COVERAGE_INVALID and exit status 1 when the report holds it in a
#         form that is not a number (#1692): the same validated readers as
#         extract_coverage_details, so the merge, the threshold check and the
#         badge never read a percentage the comment calls unreadable.
#         "0" and exit status 1 for a missing file or an unknown format.
extract_coverage_percent() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		echo "0"
		return 1
	fi

	local format percent
	format=$(detect_coverage_format "$file")

	case "$format" in
	coverage-py)
		# Python coverage.py JSON format
		percent=$(_json_percent "$file" '.totals.percent_covered')
		;;
	istanbul)
		# Istanbul/NYC JSON format (coverage-summary.json)
		if jq -e '.total.lines.pct' "$file" &>/dev/null; then
			percent=$(_json_percent "$file" '.total.lines.pct')
		elif jq -e '[to_entries[] | select(.key != "total") | .value.lines] | length > 0' "$file" &>/dev/null; then
			# Full istanbul format with per-file coverage - calculate weighted average
			percent=$(jq -r "${_ISTANBUL_WEIGHTED}"' weighted("lines")' "$file" 2>/dev/null ||
				echo "$COVERAGE_INVALID")
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
		# The root element's line-rate, required by the format (#1692).
		local line_rate _branch_rate
		read -r line_rate _branch_rate < <(_cobertura_rates "$file")
		percent="$line_rate"
		[[ "$percent" == absent ]] && percent="$COVERAGE_INVALID"
		;;
	lcov)
		# LF/LH checked record by record (#1692); LF:0 overall is 0.
		local lf lh _rest
		read -r lf lh _rest < <(_lcov_read_metrics "$file")
		percent=$(_lcov_percent "$lf" "$lh" "$COVERAGE_INVALID" 0)
		;;
	json)
		# Try common JSON formats
		if jq -e '.totals.percent_covered' "$file" &>/dev/null; then
			percent=$(_json_percent "$file" '.totals.percent_covered')
		elif jq -e '.total.lines.pct' "$file" &>/dev/null; then
			percent=$(_json_percent "$file" '.total.lines.pct')
		elif jq -e '.coverage' "$file" &>/dev/null; then
			percent=$(_json_percent "$file" '.coverage')
		else
			percent="$COVERAGE_INVALID"
		fi
		;;
	*)
		echo "0"
		return 1
		;;
	esac

	# The line percentage is a percentage only when the whole report is
	# readable (#1692): a malformed branch or function total makes the gate,
	# the badge and the merge refuse the file, as the comment does.
	if [[ "$percent" != "$COVERAGE_INVALID" ]] && ! coverage_report_readable "$file" >/dev/null; then
		percent="$COVERAGE_INVALID"
	fi
	echo "$percent"
	[[ "$percent" != "$COVERAGE_INVALID" ]]
}

# Tell whether a coverage report is readable as a whole (#1692): every metric
# it holds (lines, branches, functions, statements) is a number, through the
# same validated readers as extract_coverage_details. The one validity check
# for the merge, the threshold check, the badge and the coverage comment.
# Usage: coverage_report_readable "coverage.info"
# Output: the metrics that are unreadable, one per line (lines, branches,
#         functions or statements).
# Returns: 0 readable; 1 unreadable; 2 missing file or a format no reader
#          knows (left to the caller's own checks).
coverage_report_readable() {
	local file="${1:-}" format metric value
	local COVERAGE_LINES COVERAGE_BRANCHES COVERAGE_FUNCTIONS COVERAGE_STATEMENTS
	[[ -f "$file" ]] || return 2
	format=$(detect_coverage_format "$file")
	case "$format" in
	coverage-py | istanbul | cobertura | lcov)
		extract_coverage_details "$file" 2>/dev/null || return 2
		;;
	json)
		# The summary shapes detection reads as plain json, which
		# extract_coverage_details leaves at 0: read them here.
		COVERAGE_LINES=0 COVERAGE_BRANCHES=0 COVERAGE_FUNCTIONS=0 COVERAGE_STATEMENTS=0
		if jq -e '.total | type == "object"' "$file" &>/dev/null; then
			COVERAGE_LINES=$(_json_percent "$file" '.total.lines.pct')
			COVERAGE_BRANCHES=$(_json_percent "$file" '.total | if has("branches") then .branches.pct else 0 end')
			COVERAGE_FUNCTIONS=$(_json_percent "$file" '.total | if has("functions") then .functions.pct else 0 end')
			COVERAGE_STATEMENTS=$(_json_percent "$file" '.total | if has("statements") then .statements.pct else 0 end')
		elif jq -e '.totals | type == "object"' "$file" &>/dev/null; then
			COVERAGE_LINES=$(_json_percent "$file" '.totals.percent_covered')
			COVERAGE_BRANCHES=$(_coverage_py_branches "$file")
		else
			COVERAGE_LINES=$(_json_percent "$file" '.coverage')
		fi
		;;
	*) return 2 ;;
	esac
	local unreadable=()
	for metric in lines branches functions statements; do
		value="COVERAGE_${metric^^}"
		[[ "${!value}" == "$COVERAGE_INVALID" ]] && unreadable+=("$metric")
	done
	((${#unreadable[@]} == 0)) && return 0
	printf '%s\n' "${unreadable[@]}"
	return 1
}

# Extract detailed coverage metrics from a coverage file
# Usage: extract_coverage_details "coverage.json"
# Sets: COVERAGE_LINES, COVERAGE_BRANCHES, COVERAGE_FUNCTIONS, COVERAGE_STATEMENTS
#       each a percentage, COVERAGE_NOT_MEASURED (LCOV) or COVERAGE_INVALID
#       (a value the report holds but not as a number, #1692). A metric the
#       JSON and Cobertura formats leave out keeps its old initial 0.
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
		COVERAGE_LINES=$(_json_percent "$file" '.totals.percent_covered')
		COVERAGE_BRANCHES=$(_coverage_py_branches "$file")
		;;
	istanbul)
		# Check for coverage-summary.json format with .total
		if jq -e '.total.lines.pct' "$file" &>/dev/null; then
			COVERAGE_LINES=$(_json_percent "$file" '.total.lines.pct')
			COVERAGE_BRANCHES=$(_json_percent "$file" '.total | if has("branches") then .branches.pct else 0 end')
			COVERAGE_FUNCTIONS=$(_json_percent "$file" '.total | if has("functions") then .functions.pct else 0 end')
			COVERAGE_STATEMENTS=$(_json_percent "$file" '.total | if has("statements") then .statements.pct else 0 end')
		elif jq -e '[to_entries[] | select(.key != "total") | .value.lines] | length > 0' "$file" &>/dev/null; then
			# Full istanbul format with per-file coverage - calculate weighted averages
			COVERAGE_LINES=$(_istanbul_weighted "$file" lines)
			COVERAGE_BRANCHES=$(_istanbul_weighted "$file" branches)
			COVERAGE_FUNCTIONS=$(_istanbul_weighted "$file" functions)
			COVERAGE_STATEMENTS=$(_istanbul_weighted "$file" statements)
		else
			# coverage-final.json format - cannot extract detailed coverage
			echo "Error: Istanbul coverage file does not contain coverage percentages" >&2
			echo "This appears to be coverage-final.json. Please use coverage-summary.json instead." >&2
			echo "Generate with: nyc report --reporter=json-summary" >&2
			return 1
		fi
		;;
	cobertura)
		# The root element's rates, read by a real XML parse (#1692). The
		# format requires line-rate: absent is invalid, not 0%. An absent
		# branch-rate keeps the old 0; a present one, even empty, is checked.
		local line_rate branch_rate
		read -r line_rate branch_rate < <(_cobertura_rates "$file")
		COVERAGE_LINES="$line_rate"
		[[ "$COVERAGE_LINES" == absent ]] && COVERAGE_LINES="$COVERAGE_INVALID"
		[[ "$branch_rate" == absent ]] || COVERAGE_BRANCHES="$branch_rate"
		;;
	lcov)
		# Totals checked record by record before they are added (#1692). A
		# metric no record measures (line-only LCOV omits BRF/BRH/FNF/FNH) is
		# "absent" instead of killing a `set -e` caller through a grep that
		# matched nothing (#1078).
		local lf lh bf bh ff fh
		read -r lf lh bf bh ff fh < <(_lcov_read_metrics "$file")

		# Lines are required: no LF/LH at all is invalid; LF:0 is a real report
		# of no instrumented lines and stays 0.
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

# Internal: one per-file istanbul metric through _ISTANBUL_WEIGHTED.
# Usage: _istanbul_weighted "coverage.json" lines
_istanbul_weighted() {
	jq -r "${_ISTANBUL_WEIGHTED} weighted(\"$2\")" "$1" 2>/dev/null || echo "$COVERAGE_INVALID"
}

# Export the functions and the values they read, for child shells
# shellcheck disable=SC2090 # _ISTANBUL_WEIGHTED is a jq program passed as one word
export COVERAGE_NOT_MEASURED COVERAGE_INVALID _LGTM_CI_TESTING_COV_EXTRACT_DIR _ISTANBUL_WEIGHTED
# shellcheck disable=SC2090 # _COVERAGE_JQ_DEFS is a jq program passed as one word
export _COVERAGE_JQ_DEFS
export -f _lcov_read_metrics _lcov_percent _cobertura_rates _json_percent _istanbul_weighted
export -f extract_coverage_percent extract_coverage_details coverage_report_readable
export -f _coverage_py_branches
