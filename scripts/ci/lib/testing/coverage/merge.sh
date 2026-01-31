#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Coverage merging and conversion utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/merge.sh"
#   merge_lcov_files "output.lcov" "file1.lcov" "file2.lcov"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_COVERAGE_MERGE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_COVERAGE_MERGE_LOADED=1

# Get directory of this script for sourcing dependencies
_LGTM_CI_TESTING_COV_MERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source detect.sh for format detection
# shellcheck source=../detect.sh
[[ -f "$_LGTM_CI_TESTING_COV_MERGE_DIR/detect.sh" ]] && source "$_LGTM_CI_TESTING_COV_MERGE_DIR/detect.sh"

# Source actions.sh for logging (if available)
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../actions.sh
[[ -f "$_LGTM_CI_LIB_DIR/actions.sh" ]] && source "$_LGTM_CI_LIB_DIR/actions.sh"

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
		# Fallback: concatenate and deduplicate LCOV records
		# LCOV format: TN:, SF:, DA:line,count, LF:, LH:, end_of_record
		local temp_concat
		temp_concat=$(mktemp)
		true >"$temp_concat"
		for file in "${files[@]}"; do
			if [[ -f "$file" ]]; then
				cat "$file" >>"$temp_concat"
			fi
		done

		# Deduplicate: for same SF (source file), merge DA lines by summing counts
		awk '
		BEGIN { current_sf = ""; tn = "" }
		/^TN:/ { if (tn == "") tn = $0; next }
		/^SF:/ { current_sf = substr($0, 4); next }
		/^DA:/ {
			# DA:line_number,execution_count
			split(substr($0, 4), parts, ",")
			line_num = parts[1]
			count = parts[2] + 0
			key = current_sf ":" line_num
			da_counts[key] += count
			da_files[key] = current_sf
			da_lines[key] = line_num
			next
		}
		/^LF:/ { lf[current_sf] = substr($0, 4) + 0; next }
		/^LH:/ { lh[current_sf] = substr($0, 4) + 0; next }
		/^end_of_record/ { files[current_sf] = 1; next }
		END {
			print tn
			for (sf in files) {
				print "SF:" sf
				for (key in da_files) {
					if (da_files[key] == sf) {
						print "DA:" da_lines[key] "," da_counts[key]
					}
				}
				# Recalculate LF (lines found) and LH (lines hit)
				lf_count = 0
				lh_count = 0
				for (key in da_files) {
					if (da_files[key] == sf) {
						lf_count++
						if (da_counts[key] > 0) lh_count++
					}
				}
				print "LF:" lf_count
				print "LH:" lh_count
				print "end_of_record"
			}
		}
		' "$temp_concat" >"$output"
		rm -f "$temp_concat"
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
		# Manual merge using jq - only for single file
		if [[ ${#files[@]} -eq 1 ]]; then
			cp "${files[0]}" "$output"
		else
			# Multi-file merge requires nyc for proper statement/branch merging
			echo "Error: nyc is required to merge multiple Istanbul coverage files" >&2
			echo "Install with: npm install -g nyc" >&2
			return 1
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
			# nyc report needs coverage files in a temp directory with specific naming
			local temp_dir
			temp_dir=$(mktemp -d)
			cp "$input" "$temp_dir/coverage-final.json"
			nyc report --reporter=lcovonly --temp-dir="$temp_dir" --report-dir="$temp_dir" 2>/dev/null
			if [[ -f "$temp_dir/lcov.info" ]]; then
				cp "$temp_dir/lcov.info" "$output"
			else
				# Fallback to manual conversion
				_convert_istanbul_to_lcov "$input" "$output"
			fi
			rm -rf "$temp_dir"
		else
			_convert_istanbul_to_lcov "$input" "$output"
		fi
		;;
	"coverage-py->lcov")
		if command -v coverage &>/dev/null; then
			# coverage lcov requires .coverage file - set COVERAGE_FILE to use input
			COVERAGE_FILE="$input" coverage lcov -o "$output" 2>/dev/null || {
				log_warn "coverage lcov failed - may need .coverage file instead of JSON"
				return 1
			}
		else
			# coverage.py JSON doesn't easily convert without the tool
			log_warn "coverage tool not available for coverage-py->lcov conversion"
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

	# Parse Cobertura XML and emit LCOV format with DA lines
	# Cobertura structure: <class filename="..."><lines><line number="N" hits="H"/></lines></class>
	awk '
	BEGIN { print "TN:" }
	/<class[^>]+filename="/ {
		# Extract filename from class element
		match($0, /filename="[^"]*"/)
		if (RSTART > 0) {
			filename = substr($0, RSTART + 10, RLENGTH - 11)
			in_class = 1
			print "SF:" filename
			lf = 0
			lh = 0
		}
	}
	/<line[^>]+number="[0-9]+"[^>]+hits="[0-9]+"/ && in_class {
		# Extract line number and hits
		match($0, /number="[0-9]+"/)
		if (RSTART > 0) {
			line_num = substr($0, RSTART + 8, RLENGTH - 9)
		}
		match($0, /hits="[0-9]+"/)
		if (RSTART > 0) {
			hits = substr($0, RSTART + 6, RLENGTH - 7)
		}
		print "DA:" line_num "," hits
		lf++
		if (hits > 0) lh++
	}
	/<\/class>/ && in_class {
		print "LF:" lf
		print "LH:" lh
		print "end_of_record"
		in_class = 0
	}
	' "$input" >"$output"
}

# Internal: Convert Istanbul JSON to LCOV format
_convert_istanbul_to_lcov() {
	local input="${1:-}"
	local output="${2:-}"

	# Use jq for basic conversion - capture .value as $file for correct scope
	jq -r '
		to_entries[] |
		select(.key != "total") |
		. as $entry |
		$entry.value as $file |
		"TN:\nSF:\($file.path // $entry.key)\n" +
		($file.statementMap | to_entries | map(
			.key as $k |
			"DA:\(.value.start.line),\(if $file.s[$k] then $file.s[$k] else 0 end)"
		) | join("\n")) +
		"\nend_of_record"
	' "$input" >"$output" 2>/dev/null || {
		# Fallback: just create a minimal LCOV
		echo "TN:" >"$output"
	}
}

# Export functions
export -f merge_lcov_files merge_istanbul_files convert_coverage
