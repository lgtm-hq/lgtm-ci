#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: TAP (bats --tap) result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/tap.sh"
#   parse_tap_file "bats-output.tap"
#
# Counts test lines only: "ok N ..." and "not ok N ...". A line carrying a
# "# skip" directive is a skipped test (bats emits "ok N name # skip reason"),
# counted under skipped and not under passed.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_TAP_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_TAP_LOADED=1

# Parse a TAP stream and extract test counts
# Usage: parse_tap_file "bats-output.tap"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL
# Returns: 0 parsed; 1 file missing (counts zero)
parse_tap_file() {
	local file="${1:-}"

	TESTS_PASSED=0
	TESTS_FAILED=0
	TESTS_SKIPPED=0
	TESTS_TOTAL=0

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	read -r TESTS_PASSED TESTS_FAILED TESTS_SKIPPED TESTS_TOTAL < <(
		awk '
			BEGIN { ok = 0; notok = 0; skipped = 0 }
			/^ok [0-9]+/ {
				if (tolower($0) ~ /# *skip/) { skipped++ } else { ok++ }
				next
			}
			/^not ok [0-9]+/ { notok++ }
			END { printf "%d %d %d %d\n", ok, notok, skipped, ok + notok + skipped }
		' "$file"
	)
	return 0
}

# One or more TAP files to results.v1 on stdout (counts are summed).
# Usage: tap_results_v1 "bats-output.tap" [more.tap ...]
# Reads: RESULTS_TOOL (default bats), RESULTS_RUNNER (default run-bats-tests),
#        EXIT_CODE, TESTS_DURATION_MS, COVERAGE_LINES, MATRIX_KEY, MATRIX_VALUE,
#        RESULTS_ARTIFACTS, RESULTS_SOURCE_VERSION
tap_results_v1() {
	local parse_status="ok"
	local file passed=0 failed=0 skipped=0 total=0 seen=0

	for file in "$@"; do
		if parse_tap_file "$file"; then
			seen=$((seen + 1))
			passed=$((passed + TESTS_PASSED))
			failed=$((failed + TESTS_FAILED))
			skipped=$((skipped + TESTS_SKIPPED))
			total=$((total + TESTS_TOTAL))
		fi
	done
	if [[ "$seen" -eq 0 ]]; then
		parse_status="missing"
	fi
	TESTS_PASSED=$passed
	TESTS_FAILED=$failed
	TESTS_SKIPPED=$skipped
	TESTS_TOTAL=$total

	RESULTS_TOOL="${RESULTS_TOOL:-bats}" RESULTS_RUNNER="${RESULTS_RUNNER:-run-bats-tests}" \
		RESULTS_PARSE_STATUS="$parse_status" results_v1_build
}

# Export functions
export -f parse_tap_file tap_results_v1
