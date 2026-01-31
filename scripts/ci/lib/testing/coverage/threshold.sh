#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Coverage threshold checking utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/threshold.sh"
#   check_coverage_threshold 85.5 80

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_COVERAGE_THRESHOLD_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_COVERAGE_THRESHOLD_LOADED=1

# Check if coverage meets a threshold
# Usage: check_coverage_threshold 85.5 80
# Returns: 0 if coverage >= threshold, 1 otherwise, 2 for invalid input
check_coverage_threshold() {
	local coverage="${1:-0}"
	local threshold="${2:-0}"

	# Validate numeric inputs (non-negative only for coverage/threshold)
	if ! [[ "$coverage" =~ ^[0-9]*\.?[0-9]+$ ]]; then
		echo "Error: coverage value '$coverage' is not a valid non-negative number" >&2
		return 2
	fi
	if ! [[ "$threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
		echo "Error: threshold value '$threshold' is not a valid non-negative number" >&2
		return 2
	fi

	# Use awk for floating point comparison
	awk -v cov="$coverage" -v thresh="$threshold" 'BEGIN { exit (cov >= thresh ? 0 : 1) }'
}

# Get coverage delta between two values
# Usage: get_coverage_delta 85.5 80.0
# Output: +5.5 or -5.5 (no trailing newline for inline usage)
get_coverage_delta() {
	local current="${1:-0}"
	local previous="${2:-0}"

	# Validate numeric inputs
	if ! [[ "$current" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
		echo "Error: current value '$current' is not a valid number" >&2
		return 2
	fi
	if ! [[ "$previous" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
		echo "Error: previous value '$previous' is not a valid number" >&2
		return 2
	fi

	awk -v cur="$current" -v prev="$previous" 'BEGIN {
		delta = cur - prev
		if (delta >= 0) {
			printf "+%.2f", delta
		} else {
			printf "%.2f", delta
		}
	}'
}

# Export functions
export -f check_coverage_threshold get_coverage_delta
