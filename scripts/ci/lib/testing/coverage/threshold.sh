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

# Export functions
export -f check_coverage_threshold get_coverage_delta
