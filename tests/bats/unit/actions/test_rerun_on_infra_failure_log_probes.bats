#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Raw per-job log probe behavior and budgets for rerun-on-infra-failure.sh
# Bats isolates each test environment, including exported configuration.
# shellcheck disable=SC2030,SC2031

load "../../../helpers/rerun_on_infra_failure"

# =============================================================================
# Log-ingestion probe instrumentation (#794)
# =============================================================================
#
# Evidence gathering, not a behaviour change: on every empty `--log-failed`
# attempt the script also asks the raw per-job log endpoint what it has, and
# records both answers in the step summary. The tests below pin down the two
# properties that make that safe — it is bounded, and it never touches the
# verdict.

@test "rerun-on-infra-failure: an empty log payload probes the raw per-job logs" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" "##[error]The runner has received a shutdown signal"
	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(_call_count "$API_CALLS")"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Log-ingestion probe evidence (#794)"
	# Table-shaped needle: a bare "available" also matches "unavailable".
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "\`55501\` (failure) | available |"
	assert_output --partial "#794 probe: attempt 1, job 55501"
}

@test "rerun-on-infra-failure: the probe lists the attempt jobs with --paginate" {
	# A matrix run can exceed the endpoint's 100-jobs-per-page limit, so an
	# unpaginated listing would quietly drop the very jobs worth probing.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--paginate" "$API_CALLS"
	assert_output "1"
	run grep -cF "actions/runs/${RUN_ID}/attempts/1/jobs" "$API_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: the probe selects failed, cancelled and timed-out jobs only" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	run bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$API_CALLS" 'select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")'
}

@test "rerun-on-infra-failure: probe evidence does not change the inconclusive verdict" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" "The runner has received a shutdown signal"
	run bash "$SCRIPT"
	# A signature in the *probed* log is evidence, never a trigger: the raw log
	# is not the matcher's input until #794's evidence gate passes.
	assert_success
	assert_output --partial "::warning::Inconclusive"
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: logs unavailable."
}

@test "rerun-on-infra-failure: probe evidence does not change a matched verdict" {
	_mock_gh_attempts "0:" "0:Failed to resolve action download info"
	_mock_sleep
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" "nothing infra-shaped here"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Log-ingestion probe evidence (#794)"
}

@test "rerun-on-infra-failure: probe evidence does not change an unmatched verdict" {
	_mock_gh_attempts "0:" "0:assertion failed: expected 200 got 500"
	_mock_sleep
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" "The runner has received a shutdown signal"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No infra signature matched"
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "The failure looks real"
}

@test "rerun-on-infra-failure: a failing job listing is recorded, not fatal" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	_probe_listing "1"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::Inconclusive"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "job listing failed (gh exit 1)"
}

@test "rerun-on-infra-failure: a failing per-job log probe is recorded, not fatal" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "1" "BlobNotFound"
	run bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "unavailable (gh exit 1)"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: logs unavailable."
}

@test "rerun-on-infra-failure: an empty per-job log body is recorded as empty" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	_probe_listing "0" "$(printf '55501\tcancelled\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" ""
	run bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "\`55501\` (cancelled) | empty | 0 |"
}

@test "rerun-on-infra-failure: the probe stops at its per-attempt job ceiling" {
	# A big matrix must not turn the safety net into an API storm: one listing
	# plus at most LOG_PROBE_MAX_JOBS log fetches per empty attempt.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	local rows=() i
	for i in 1 2 3 4 5 6 7 8; do
		rows+=("$(printf '5550%s\tfailure\t2026-08-31T10:00:00Z' "$i")")
	done
	_probe_listing "0" "${rows[@]}"
	_probe_job_log "default" "0" "some raw log"
	run bash "$SCRIPT"
	assert_success
	# 1 listing + 5 job logs, never 1 + 8.
	assert_equal "6" "$(_call_count "$API_CALLS")"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "probe ceiling reached"
}

@test "rerun-on-infra-failure: LOG_PROBE_MAX_CALLS bounds the probe across attempts" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_PROBE_MAX_CALLS="3"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "default" "0" "some raw log"
	run bash "$SCRIPT"
	assert_success
	# Five empty attempts would spend ten calls unbounded; the budget caps it.
	assert_equal "3" "$(_call_count "$API_CALLS")"
	# An exhausted budget is stated, never a silent gap in the table: otherwise
	# "the later attempts found nothing" and "the later attempts went unprobed"
	# read identically.
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "not probed: call budget of 3 spent"
}

@test "rerun-on-infra-failure: the attempt-jobs listing is fetched once and reused" {
	# The run is complete and the attempt is pinned, so its job conclusions are
	# immutable — refetching the listing per attempt would just burn the call
	# budget that the per-job probes need.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="3"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" "some raw log"
	run bash "$SCRIPT"
	assert_success
	run grep -cF "actions/runs/${RUN_ID}/attempts/1/jobs" "$API_CALLS"
	assert_output "1"
	# One listing plus one per-job probe on each of the three empty attempts.
	assert_equal "4" "$(_call_count "$API_CALLS")"
}

@test "rerun-on-infra-failure: an empty listing is retried rather than cached" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="3"
	_probe_listing "0"
	run bash "$SCRIPT"
	assert_success
	run grep -cF "actions/runs/${RUN_ID}/attempts/1/jobs" "$API_CALLS"
	assert_output "3"
}

@test "rerun-on-infra-failure: probe calls run under their own short timeout" {
	# Not GH_CMD_TIMEOUT: that bound is sized for a log-archive download, and
	# the probe must never be able to spend the fetch loop's time budget.
	export TIMEOUT_CALLS="${BATS_TEST_TMPDIR}/timeout_calls"
	export LOG_PROBE_CMD_TIMEOUT="7"
	export LOG_FETCH_ATTEMPTS="1"
	: >"$TIMEOUT_CALLS"
	_mock_gh_attempts "0:"
	_mock_sleep
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" "some raw log"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "7 gh api" "$TIMEOUT_CALLS"
	assert_output "2"
}

@test "rerun-on-infra-failure: the probe is skipped when the fetch deadline has no room" {
	# The invariant that keeps the probe observational: it runs between two
	# deadline checks, so unbudgeted probe calls could push the next check past
	# LOG_FETCH_DEADLINE and cost the run attempts 2-5 — a rerun lost *because*
	# of the instrumentation.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_DEADLINE="90"
	export GH_CMD_TIMEOUT="80"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "0" "some raw log"
	run bash "$SCRIPT"
	assert_success
	assert_equal "0" "$(_call_count "$API_CALLS")"
	# The fetch loop is untouched: all five attempts still run, and the verdict
	# is the one the loop reached on its own.
	assert_equal "5" "$(_call_count "$FETCH_CALLS")"
	assert_output --partial "::warning::Inconclusive"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: logs unavailable."
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "not probed:"
}

@test "rerun-on-infra-failure: LOG_PROBE_MAX_CALLS of zero disables the probe silently" {
	# A documented off switch has to be off: no calls, no rows, and no evidence
	# section explaining that there is no evidence.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_PROBE_MAX_CALLS="0"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	run bash "$SCRIPT"
	assert_success
	assert_equal "0" "$(_call_count "$API_CALLS")"
	run grep -cE "Log-ingestion probe evidence|not probed" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

@test "rerun-on-infra-failure: stalled probes never cost the fetch loop an attempt" {
	# Probe time is credited back to the loop's deadline. Without the credit the
	# three probe stalls below (2s each) would push attempt 3 past
	# LOG_FETCH_DEADLINE=10s, and a payload arriving on that attempt would go
	# unmatched — the instrumentation changing the verdict.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="3"
	export LOG_FETCH_DEADLINE="10"
	export GH_CMD_TIMEOUT="1"
	export LOG_PROBE_CMD_TIMEOUT="2"
	export LOG_PROBE_MAX_JOBS="3"
	_probe_listing "0" \
		"$(printf '55501\tfailure\t2026-08-31T10:00:00Z')" \
		"$(printf '55502\tfailure\t2026-08-31T10:00:00Z')" \
		"$(printf '55503\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "default" "hang" "30"
	run bash "$SCRIPT"
	assert_success
	assert_equal "3" "$(_call_count "$FETCH_CALLS")"
	assert_output --partial "::warning::Inconclusive"
	refute_output --partial "Log-fetch deadline of"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: logs unavailable."
	# A probe killed at LOG_PROBE_CMD_TIMEOUT is its own evidence state: "the
	# raw endpoint did not answer in time" is not "the raw endpoint is empty".
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| timed out | 0 |"
}

@test "rerun-on-infra-failure: total probe spend respects LOG_PROBE_TIME_BUDGET" {
	# The other half of the credit: unbounded probe spend would push the script
	# into WATCHDOG_DEADLINE, whose SIGKILL lands before the evidence is
	# flushed. Each stalled probe costs 2s, so a 10s budget stops well short of
	# the nine probes this listing and attempt count would otherwise make.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="3"
	export LOG_PROBE_CMD_TIMEOUT="2"
	export LOG_PROBE_TIME_BUDGET="10"
	export LOG_PROBE_MAX_JOBS="3"
	_probe_listing "0" \
		"$(printf '55501\tfailure\t2026-08-31T10:00:00Z')" \
		"$(printf '55502\tfailure\t2026-08-31T10:00:00Z')" \
		"$(printf '55503\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "default" "hang" "30"
	run bash "$SCRIPT"
	assert_success
	# The summary marker is the contract, not a wall-clock reading: nine probes
	# would stall for 18s, and the budget is what stops them — but asserting on
	# elapsed seconds only measures how loaded the runner is.
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "probe time budget spent"
}

@test "rerun-on-infra-failure: a failing probe records a sanitized stderr tail" {
	# An egress block and a genuine 404 both surface as a non-zero gh exit. The
	# first line of stderr is what tells them apart, and #794's evidence is
	# worthless if it cannot.
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1"
	_probe_listing "0" "$(printf '55501\tfailure\t2026-08-31T10:00:00Z')"
	_probe_job_log "55501" "1" ""
	# The stub writes the log payload to stdout; make it talk on stderr instead.
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		exit 0
		;;
	"api "*"/attempts/"*"/jobs"*)
		echo "\$*" >> '${API_CALLS}'
		cat '${PROBE_DIR}/listing'
		;;
	"api "*"/actions/jobs/"*"/logs"*)
		echo "\$*" >> '${API_CALLS}'
		echo 'dial tcp 20.150.0.1:443: i/o timeout' >&2
		exit 1
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	run bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "dial tcp 20.150.0.1:443: i/o timeout"
	assert_output --partial "dial tcp 20.150.0.1:443: i/o timeout"
}

@test "rerun-on-infra-failure: LOG_PROBE_MAX_JOBS of zero disables the probe" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_PROBE_MAX_JOBS="0"
	run bash "$SCRIPT"
	assert_success
	assert_equal "0" "$(_call_count "$API_CALLS")"
	run grep -cF "Log-ingestion probe evidence" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

@test "rerun-on-infra-failure: a non-empty log payload never probes" {
	# The happy path pays nothing for the instrumentation: no listing, no log
	# fetch, no evidence section.
	_mock_gh_attempts "0:The runner has received a shutdown signal"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_equal "0" "$(_call_count "$API_CALLS")"
	run grep -cF "Log-ingestion probe evidence" "$GITHUB_STEP_SUMMARY"
	assert_failure
}
