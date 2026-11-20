#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Check if coverage meets a minimum threshold
#
# Required environment variables:
#   COVERAGE - Current coverage percentage (0 to 100)
#   THRESHOLD - Minimum coverage percentage required (0 to 100)
#
# Optional environment variables:
#   FAIL_ON_ERROR - Whether to fail if below threshold (default: true)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

: "${COVERAGE:=0}"
: "${THRESHOLD:=0}"
: "${FAIL_ON_ERROR:=true}"

# Validate numeric inputs
# A percentage is a number from 0 to 100 (#1692): a threshold of 100.5 can
# never be met, and coverage of 150 is no reading at all.
_is_percentage() {
	[[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v p="$1" 'BEGIN { exit (p <= 100 ? 0 : 1) }'
}
if ! _is_percentage "$COVERAGE"; then
	log_error "Invalid COVERAGE value: $COVERAGE (must be a number from 0 to 100)"
	exit 1
fi
if ! _is_percentage "$THRESHOLD"; then
	log_error "Invalid THRESHOLD value: $THRESHOLD (must be a number from 0 to 100)"
	exit 1
fi

# Skip check if threshold is 0 (already validated as numeric above)
if awk -v t="$THRESHOLD" 'BEGIN { exit (t > 0 ? 1 : 0) }'; then
	set_github_output "passed" "true"
	set_github_output "message" "Coverage check skipped (threshold is 0)"
	log_info "Coverage check skipped (threshold is 0)"
	exit 0
fi

# Compare coverage to threshold
if awk -v c="$COVERAGE" -v t="$THRESHOLD" 'BEGIN { exit (c >= t ? 0 : 1) }'; then
	set_github_output "passed" "true"
	set_github_output "message" "Coverage ${COVERAGE}% meets threshold ${THRESHOLD}%"
	log_success "Coverage ${COVERAGE}% meets threshold ${THRESHOLD}%"
else
	set_github_output "passed" "false"
	set_github_output "message" "Coverage ${COVERAGE}% is below threshold ${THRESHOLD}%"
	log_error "Coverage ${COVERAGE}% is below threshold ${THRESHOLD}%"
	if [[ "$FAIL_ON_ERROR" == "true" ]]; then
		exit 1
	fi
fi
