#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Timeout and watchdog supervision for rerun-on-infra-failure.sh
# Bats isolates each test environment, including exported configuration.
# shellcheck disable=SC2030,SC2031

load "../../../helpers/rerun_on_infra_failure"

@test "rerun-on-infra-failure: a missing timeout binary fails loudly instead of running unbounded" {
	export TIMEOUT_BIN="lgtm-ci-no-such-timeout"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "TIMEOUT_BIN 'lgtm-ci-no-such-timeout' not found on PATH"
	[ ! -s "$FETCH_CALLS" ]
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: falls back to gtimeout when timeout is absent" {
	# `runner-image` is a caller input and macOS ships no `timeout`; hardcoding
	# the name would silently disable the safety net on any such runner.
	export TIMEOUT_CALLS="${BATS_TEST_TMPDIR}/timeout_calls"
	: >"$TIMEOUT_CALLS"
	_mock_gh "Failed to resolve action download info"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mv "${mock_bin}/timeout" "${mock_bin}/gtimeout"
	PATH="${mock_bin}:$(_minimal_path_dir)"
	export PATH
	run env -u BASH_ENV bash "$SCRIPT"
	assert_success
	# Log fetch, #967 failed-jobs listing, rerun.
	assert_equal "3" "$(_call_count "$TIMEOUT_CALLS")"
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: no timeout binary at all fails loudly" {
	_mock_gh "Failed to resolve action download info"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	rm -f "${mock_bin}/timeout"
	PATH="${mock_bin}:$(_minimal_path_dir)"
	export PATH
	run env -u BASH_ENV bash "$SCRIPT"
	assert_failure
	assert_output --partial "Neither 'timeout' nor 'gtimeout' is on PATH"
	[ ! -s "$FETCH_CALLS" ]
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: both the log fetch and the rerun run under GH_CMD_TIMEOUT" {
	export TIMEOUT_CALLS="${BATS_TEST_TMPDIR}/timeout_calls"
	export GH_CMD_TIMEOUT="42"
	: >"$TIMEOUT_CALLS"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_success
	# Log fetch, #967 failed-jobs listing, rerun: every gh call is bounded.
	assert_equal "3" "$(_call_count "$TIMEOUT_CALLS")"
	run grep -c -- "42 gh api" "$TIMEOUT_CALLS"
	assert_output "1"
	run grep -c -- "42 gh run view" "$TIMEOUT_CALLS"
	assert_output "1"
	run grep -c -- "42 gh run rerun" "$TIMEOUT_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: a fetch that hangs past GH_CMD_TIMEOUT is retried, not fatal" {
	export GH_CMD_TIMEOUT="1"
	export LOG_FETCH_DEADLINE="60"
	_mock_gh_attempts "hang:30" "0:The runner has received a shutdown signal"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "exceeded GH_CMD_TIMEOUT=1s and was killed"
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: a fetch that hangs on every attempt is its own outcome" {
	export GH_CMD_TIMEOUT="1"
	export LOG_FETCH_DEADLINE="60"
	export LOG_FETCH_ATTEMPTS="2"
	_mock_gh_attempts "hang:30"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::Timed out reading the failed-job logs"
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Timed out reading logs."
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "command"
	# Distinct from both other non-rerun outcomes, so triage cannot conflate a
	# hang with GitHub's ingestion lag or with a genuine failure.
	run grep -cF "Inconclusive: logs unavailable" "$GITHUB_STEP_SUMMARY"
	assert_failure
	run grep -cF "The failure looks real" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

@test "rerun-on-infra-failure: the timeout summary says the safety net bounded itself" {
	# Both real occurrences read as `cancelled` at run level and were misread as
	# a GitHub-side cancellation; the summary has to make the timeout obvious.
	export GH_CMD_TIMEOUT="1"
	export LOG_FETCH_ATTEMPTS="1"
	_mock_gh_attempts "hang:30"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "timeout in the safety net itself"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "GH_CMD_TIMEOUT=1"
}

@test "rerun-on-infra-failure: LOG_FETCH_DEADLINE short-circuits the remaining attempts" {
	# Five attempts are configured, but the first hanging fetch already spends
	# the whole wall-clock budget, so the loop must not start a second one.
	export GH_CMD_TIMEOUT="1"
	export LOG_FETCH_DEADLINE="1"
	_mock_gh_attempts "hang:30"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Log-fetch deadline of 1s reached"
	assert_equal "1" "$(_call_count "$FETCH_CALLS")"
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "deadline"
}

@test "rerun-on-infra-failure: a rerun that hangs past GH_CMD_TIMEOUT fails loudly" {
	export GH_CMD_TIMEOUT="1"
	_mock_gh "Failed to resolve action download info" "30"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Timed out re-running failed jobs of run ${RUN_ID} after 1s"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "press re-run manually"
	refute_output --partial "::notice::"
}

@test "rerun-on-infra-failure: a megabyte of failed-job log is classified in seconds, not minutes" {
	# The #776 regression. `${logs//[[:space:]]/}` on this payload measured 21s
	# at 1 MB and 147s at 4 MB, so a real multi-megabyte failed-job log burned
	# the whole 10-minute job timeout inside one parameter expansion — on the
	# success path, where nothing is logged, hence ten minutes of zero output.
	# The bound here is deliberately far above the fixed cost (well under a
	# second) and far below the quadratic one.
	_mock_gh_large_log $((1024 * 1024)) "The runner has received a shutdown signal"
	local start=$SECONDS
	run bash "$SCRIPT"
	local elapsed=$((SECONDS - start))
	assert_success
	[ "$elapsed" -lt 15 ]
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: children get /dev/null on stdin, never the caller's" {
	# An inherited stdin is the other way to block forever while printing
	# nothing. The probe reads with a timeout: against /dev/null `read` reports
	# EOF immediately, against an open fifo it would block for the full 5s.
	local probe="${BATS_TEST_TMPDIR}/stdin_probe"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
if read -r -t 5 _; then
	echo "readable" >>'${probe}'
else
	echo "eof=\$?" >>'${probe}'
fi
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		echo "The runner has received a shutdown signal"
		;;
	api\ *jobs*) printf '7\ttest\t3\n' ;;
	run\ rerun\ *) echo "\$*" >> '${RERUN_CALLS}' ;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	_mock_timeout
	export PATH="${mock_bin}:$PATH"

	local fifo="${BATS_TEST_TMPDIR}/stdin.fifo"
	mkfifo "$fifo"
	# fd 9 holds the fifo open for read and write, so an inherited stdin would
	# block rather than see EOF — exactly the shape of the hang being excluded.
	run bash -c 'exec 9<>"$1"; bash "$2" <&9' _ "$fifo" "$SCRIPT"
	assert_success
	# Log fetch, #967 failed-jobs listing, rerun.
	run grep -c "^eof=1$" "$probe"
	assert_output "3"
}

@test "rerun-on-infra-failure: the watchdog turns a hang into a diagnostic and exits 0" {
	# `timeout` bounds gh; nothing bounded the shell itself, and #776 hung
	# inside bash. The watchdog is the outermost bound, and per #763 the safety
	# net declining to act must never redden the job.
	export WATCHDOG_DEADLINE="2"
	export GH_CMD_TIMEOUT="60"
	_mock_gh_attempts "hang:60"
	local start=$SECONDS
	run bash "$SCRIPT"
	local elapsed=$((SECONDS - start))
	assert_success
	[ "$elapsed" -lt 30 ]
	assert_output --partial "::warning::Auto re-run for run ${RUN_ID} exceeded its own 2s budget"
	# The diagnostic names where it was stuck, which is the whole point: the
	# real occurrence left nothing at all to triage from.
	assert_output --partial "stopped while: Fetching failed-job logs of run ${RUN_ID}"
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Watchdog stopped the safety net."
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "WATCHDOG_DEADLINE=2"
}

@test "rerun-on-infra-failure: the watchdog stays out of the way of a normal run" {
	export WATCHDOG_DEADLINE="300"
	_mock_gh "The runner has received a shutdown signal"
	run bash "$SCRIPT"
	assert_success
	refute_output --partial "Watchdog"
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: a watchdog-stopped run leaves no scratch state behind" {
	export WATCHDOG_DEADLINE="2"
	export GH_CMD_TIMEOUT="60"
	export TMPDIR="${BATS_TEST_TMPDIR}/scratch"
	mkdir -p "$TMPDIR"
	_mock_gh_attempts "hang:60"
	run bash "$SCRIPT"
	assert_success
	run bash -c 'shopt -s nullglob; leftovers=("$1"/rerun-on-infra-failure.*); echo "${#leftovers[@]}"' _ "$TMPDIR"
	assert_output "0"
}
