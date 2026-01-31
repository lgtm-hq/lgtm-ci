#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Vulnerability severity utilities (conversion, comparison)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/severity.sh"
#   severity_to_number "critical"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_SBOM_SEVERITY_LOADED:-}" ]] && return 0
readonly _LGTM_CI_SBOM_SEVERITY_LOADED=1

# =============================================================================
# Severity Constants
# =============================================================================

# Severity levels (ordered from lowest to highest)
readonly SEVERITY_UNKNOWN=0
readonly SEVERITY_NEGLIGIBLE=1
readonly SEVERITY_LOW=2
readonly SEVERITY_MEDIUM=3
readonly SEVERITY_HIGH=4
readonly SEVERITY_CRITICAL=5

# =============================================================================
# Severity Functions
# =============================================================================

# Convert severity string to numeric value
# Usage: severity_to_number "critical"
# Returns: numeric value (0-5) for comparison
severity_to_number() {
	local severity="${1,,}" # lowercase

	case "$severity" in
	critical)
		echo "$SEVERITY_CRITICAL"
		;;
	high)
		echo "$SEVERITY_HIGH"
		;;
	medium)
		echo "$SEVERITY_MEDIUM"
		;;
	low)
		echo "$SEVERITY_LOW"
		;;
	negligible)
		echo "$SEVERITY_NEGLIGIBLE"
		;;
	*)
		echo "$SEVERITY_UNKNOWN"
		;;
	esac
}

# Convert numeric severity to string
# Usage: number_to_severity 5
# Returns: "critical"
number_to_severity() {
	local number="$1"

	case "$number" in
	"$SEVERITY_CRITICAL" | 5)
		echo "critical"
		;;
	"$SEVERITY_HIGH" | 4)
		echo "high"
		;;
	"$SEVERITY_MEDIUM" | 3)
		echo "medium"
		;;
	"$SEVERITY_LOW" | 2)
		echo "low"
		;;
	"$SEVERITY_NEGLIGIBLE" | 1)
		echo "negligible"
		;;
	*)
		echo "unknown"
		;;
	esac
}

# Compare two severity levels
# Usage: compare_severity "high" "critical"
# Returns: -1 if first < second, 0 if equal, 1 if first > second
compare_severity() {
	local sev1="${1,,}"
	local sev2="${2,,}"
	local num1 num2

	num1=$(severity_to_number "$sev1")
	num2=$(severity_to_number "$sev2")

	if ((num1 < num2)); then
		echo "-1"
	elif ((num1 > num2)); then
		echo "1"
	else
		echo "0"
	fi
}

# Check if severity meets or exceeds threshold
# Usage: severity_meets_threshold "high" "medium"
# Returns: 0 (true) if severity >= threshold, 1 (false) otherwise
severity_meets_threshold() {
	local severity="$1"
	local threshold="$2"
	local result

	result=$(compare_severity "$severity" "$threshold")
	[[ "$result" -ge 0 ]]
}

# Check if a severity should fail based on fail-on setting
# Usage: should_fail_on_severity "high" "medium"
# Returns: 0 (true) if severity should cause failure
should_fail_on_severity() {
	local severity="$1"
	local fail_on="$2"

	# If fail_on is empty or "none", never fail
	if [[ -z "$fail_on" || "${fail_on,,}" == "none" ]]; then
		return 1
	fi

	severity_meets_threshold "$severity" "$fail_on"
}

# Get color code for severity (for terminal output)
# Usage: severity_color "critical"
severity_color() {
	local severity="${1,,}"

	case "$severity" in
	critical)
		printf '\033[0;31m' # Red
		;;
	high)
		printf '\033[0;91m' # Bright red
		;;
	medium)
		printf '\033[0;33m' # Yellow
		;;
	low)
		printf '\033[0;34m' # Blue
		;;
	negligible)
		printf '\033[0;90m' # Gray
		;;
	*)
		printf '\033[0m' # Default
		;;
	esac
}

# Get emoji for severity (for markdown output)
# Usage: severity_emoji "critical"
severity_emoji() {
	local severity="${1,,}"

	case "$severity" in
	critical)
		echo ":red_circle:"
		;;
	high)
		echo ":orange_circle:"
		;;
	medium)
		echo ":yellow_circle:"
		;;
	low)
		echo ":blue_circle:"
		;;
	negligible)
		echo ":white_circle:"
		;;
	*)
		echo ":black_circle:"
		;;
	esac
}

# =============================================================================
# Export functions
# =============================================================================
export -f severity_to_number number_to_severity compare_severity
export -f severity_meets_threshold should_fail_on_severity
export -f severity_color severity_emoji
