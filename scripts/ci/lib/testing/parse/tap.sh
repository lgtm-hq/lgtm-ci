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
#
# Plan shortfall (#1531) is informational only. The first "1..N" line is read
# as the plan, and a stream with fewer result lines than N is recorded in the
# results document's "tap_plan" property. It never changes the status: under
# kcov the stream also carries xtrace output and nested TAP from tests that
# run bats themselves, so no TAP-based rule can prove a run finished. Sharded
# coverage gates completion on GitHub step state instead (shard-completion.py).

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_TAP_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_TAP_LOADED=1

# Parse a TAP stream and extract test counts
# Usage: parse_tap_file "bats-output.tap"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL,
#       TAP_PLAN (N of the first "1..N" line; empty without one)
# Returns: 0 parsed; 1 file missing (counts zero)
parse_tap_file() {
	local file="${1:-}"

	TESTS_PASSED=0
	TESTS_FAILED=0
	TESTS_SKIPPED=0
	TESTS_TOTAL=0
	TAP_PLAN=""

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	read -r TESTS_PASSED TESTS_FAILED TESTS_SKIPPED TESTS_TOTAL TAP_PLAN < <(
		awk '
			BEGIN { ok = 0; notok = 0; skipped = 0; plan = "-" }
			plan == "-" && /^1\.\.[0-9]+[ \t]*$/ { plan = substr($1, 4) + 0 }
			/^ok [0-9]+/ {
				if (tolower($0) ~ /# *skip/) { skipped++ } else { ok++ }
				next
			}
			/^not ok [0-9]+/ { notok++ }
			END { printf "%d %d %d %d %s\n", ok, notok, skipped, ok + notok + skipped, plan }
		' "$file"
	)
	if [[ "$TAP_PLAN" == "-" ]]; then
		TAP_PLAN=""
	fi
	return 0
}

# One or more TAP files to results.v1 on stdout (counts are summed).
# Usage: tap_results_v1 "bats-output.tap" [more.tap ...]
# Reads: RESULTS_TOOL (default bats), RESULTS_RUNNER (default run-bats-tests),
#        EXIT_CODE, TESTS_DURATION_MS, COVERAGE_LINES, MATRIX_KEY, MATRIX_VALUE,
#        RESULTS_ARTIFACTS, RESULTS_SOURCE_VERSION,
#        RESULTS_INCOMPLETE (optional caller reason the run is incomplete; the
#        sharded aggregate sets it when a shard has no completion manifest)
# When the summed result lines fall short of the summed plans, the document
# records both in "tap_plan" (informational; the status is unchanged).
tap_results_v1() {
	local parse_status="ok"
	local file passed=0 failed=0 skipped=0 total=0 seen=0 planned=0
	local incomplete="${RESULTS_INCOMPLETE:-}"

	for file in "$@"; do
		if parse_tap_file "$file"; then
			seen=$((seen + 1))
			passed=$((passed + TESTS_PASSED))
			failed=$((failed + TESTS_FAILED))
			skipped=$((skipped + TESTS_SKIPPED))
			total=$((total + TESTS_TOTAL))
			planned=$((planned + ${TAP_PLAN:-0}))
		fi
	done
	if [[ "$seen" -eq 0 ]]; then
		parse_status="missing"
	elif [[ -n "$incomplete" ]]; then
		parse_status="incomplete"
	fi
	local plan_planned="" plan_reported=""
	if [[ "$total" -lt "$planned" ]]; then
		plan_planned="$planned"
		plan_reported="$total"
	fi
	TESTS_PASSED=$passed
	TESTS_FAILED=$failed
	TESTS_SKIPPED=$skipped
	TESTS_TOTAL=$total

	RESULTS_TOOL="${RESULTS_TOOL:-bats}" RESULTS_RUNNER="${RESULTS_RUNNER:-run-bats-tests}" \
		RESULTS_PARSE_STATUS="$parse_status" RESULTS_INCOMPLETE="$incomplete" \
		RESULTS_TAP_PLANNED="$plan_planned" RESULTS_TAP_REPORTED="$plan_reported" \
		results_v1_build
}

# Export functions
export -f parse_tap_file tap_results_v1
