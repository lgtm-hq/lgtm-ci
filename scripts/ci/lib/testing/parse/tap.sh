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
# counted under skipped and not under passed. These legacy totals
# (TESTS_*) count every such line, including nested TAP that tests running
# bats themselves leak into the stream; completeness does not use them.
#
# Plan completeness (#1531): the first "1..N" line anywhere is the outer
# plan. The shard manifest writer (scripts/ci/actions/shard-completion.py)
# applies the same rule, checked against Bats 1.14 output and a real CI
# shard whose stream carried leaked nested "ok 1" lines:
#   - Top-level results are numbered 1, 2, ... N in order. After the plan,
#     a result counts only when its number is the next expected one (and at
#     most N); anything else is nested or leaked output and is ignored.
#   - Hook lines ("not ok K setup_file failed", "not ok K teardown_file
#     failed") are never top-level results: bats reuses K for the next test.
#   - No SIG marker is consulted: tests that mock bats output leak
#     "# Received SIGINT, aborting ..." lines that look exactly like a
#     real one. A real interruption always leaves the count below N.
#   - The plan is complete only when the sequential count reaches N;
#     tap_results_v1 (and the writer) also need an exit
#     code below 124. Any shortfall is incomplete. This fails closed: a real
#     setup_file failure (bats skips the rest of that file) leaves the same
#     stream as a bats-exec-file killed by SIGTERM (no marker, the same
#     "Executed X instead of expected N tests" warning, bats exit 1), so it
#     is reported as incomplete (status error, no coverage published), not
#     as failed. The job fails either way.
# A stream without a plan line is "unknown", not incomplete.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_TAP_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_TAP_LOADED=1

# Parse a TAP stream and extract test counts
# Usage: parse_tap_file "bats-output.tap"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL,
#       TAP_PLAN (N of the first "1..N" line; empty without one),
#       TAP_PLAN_STATUS (complete | incomplete | unknown),
#       TAP_TESTS (sequential top-level test results, at most N),
# Returns: 0 parsed; 1 file missing (counts zero)
parse_tap_file() {
	local file="${1:-}"

	TESTS_PASSED=0
	TESTS_FAILED=0
	TESTS_SKIPPED=0
	TESTS_TOTAL=0
	TAP_PLAN=""
	TAP_PLAN_STATUS="unknown"
	TAP_TESTS=0

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	read -r TESTS_PASSED TESTS_FAILED TESTS_SKIPPED TESTS_TOTAL TAP_PLAN \
		TAP_PLAN_STATUS TAP_TESTS < <(
			awk '
			BEGIN { ok = 0; notok = 0; skipped = 0; plan = "-"; expected = 1 }
			plan == "-" && /^1\.\.[0-9]+[ \t]*$/ {
				# Results before the plan are noise: top-level numbering starts here.
				plan = substr($1, 4) + 0; expected = 1; next
			}
			/^(not )?ok [0-9]+/ {
				# Legacy totals: every result line (see the header).
				if ($1 == "ok") {
					if (tolower($0) ~ /# *skip/) { skipped++ } else { ok++ }
				} else { notok++ }
				hook = ($0 ~ /^not ok [0-9]+ [A-Za-z_]+_file failed/)
				number = ($1 == "ok") ? $2 + 0 : $3 + 0
				if (!hook && number == expected && (plan == "-" || expected <= plan)) {
					expected++
				}
				next
			}
			END {
				total = ok + notok + skipped
				tests = expected - 1
				status = "unknown"
				if (plan != "-") {
					status = (tests == plan) ? "complete" : "incomplete"
				}
				printf "%d %d %d %d %s %s %d\n", ok, notok, skipped, total, plan,
					status, tests
			}
		' "$file"
		)
	if [[ "$TAP_PLAN" == "-" ]]; then
		TAP_PLAN=""
	fi
	return 0
}

# Describe the last parse_tap_file's shortfall; the writer words it the same.
# Usage: tap_shortfall_text
tap_shortfall_text() {
	printf '%s of %s planned tests have a result (a setup_file/hook failure or an interruption)' \
		"$TAP_TESTS" "$TAP_PLAN"
}

# One or more TAP files to results.v1 on stdout (counts are summed).
# Usage: tap_results_v1 "bats-output.tap" [more.tap ...]
# Reads: RESULTS_TOOL (default bats), RESULTS_RUNNER (default run-bats-tests),
#        EXIT_CODE, TESTS_DURATION_MS, COVERAGE_LINES, MATRIX_KEY, MATRIX_VALUE,
#        RESULTS_ARTIFACTS, RESULTS_SOURCE_VERSION,
#        RESULTS_INCOMPLETE (optional caller reason the run is incomplete)
# A file with an incomplete plan, or a RESULTS_INCOMPLETE reason, marks the
# document incomplete: parse status "incomplete" (status error) plus the
# reason, so partial counts never read as a whole run (#1531).
tap_results_v1() {
	local parse_status="ok"
	local file passed=0 failed=0 skipped=0 total=0 seen=0
	local incomplete="${RESULTS_INCOMPLETE:-}" cut_short=""

	for file in "$@"; do
		if parse_tap_file "$file"; then
			seen=$((seen + 1))
			passed=$((passed + TESTS_PASSED))
			failed=$((failed + TESTS_FAILED))
			skipped=$((skipped + TESTS_SKIPPED))
			total=$((total + TESTS_TOTAL))
			if [[ "$TAP_PLAN_STATUS" == "incomplete" ]]; then
				cut_short+="${cut_short:+; }${file} did not finish: $(tap_shortfall_text)"
			fi
		fi
	done
	if [[ -z "$incomplete" && -n "$cut_short" ]]; then
		incomplete="incomplete test results: ${cut_short}"
	fi
	# Same exit rule as the shard manifest writer: 124 is a timeout, 125-127
	# a timeout(1) failure, 128+ a signal; the run did not finish.
	if [[ -z "$incomplete" && "${EXIT_CODE:-}" =~ ^[0-9]+$ && "${EXIT_CODE}" -ge 124 ]]; then
		incomplete="incomplete test results: run exited ${EXIT_CODE} (timed out or killed)"
	fi
	if [[ "$seen" -eq 0 ]]; then
		parse_status="missing"
	elif [[ -n "$incomplete" ]]; then
		parse_status="incomplete"
	fi
	TESTS_PASSED=$passed
	TESTS_FAILED=$failed
	TESTS_SKIPPED=$skipped
	TESTS_TOTAL=$total

	RESULTS_TOOL="${RESULTS_TOOL:-bats}" RESULTS_RUNNER="${RESULTS_RUNNER:-run-bats-tests}" \
		RESULTS_PARSE_STATUS="$parse_status" RESULTS_INCOMPLETE="$incomplete" \
		results_v1_build
}

# Export functions
export -f parse_tap_file tap_shortfall_text tap_results_v1
