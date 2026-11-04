#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Validation, signatures, eligibility and protection for rerun-on-infra-failure.sh
# Bats isolates each test environment, including exported configuration.
# shellcheck disable=SC2030,SC2031

load "../../../helpers/rerun_on_infra_failure"

# =============================================================================
# Required env var validation
# =============================================================================

@test "rerun-on-infra-failure: fails when RUN_ID is unset" {
	_mock_gh "irrelevant"
	run bash -c 'unset RUN_ID; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "RUN_ID is required"
}

@test "rerun-on-infra-failure: fails when RUN_ATTEMPT is unset" {
	_mock_gh "irrelevant"
	run bash -c 'unset RUN_ATTEMPT; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "RUN_ATTEMPT is required"
}

@test "rerun-on-infra-failure: non-numeric RUN_ATTEMPT fails with a clear error" {
	export RUN_ATTEMPT="not-a-number"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::RUN_ATTEMPT must be a non-negative integer (got 'not-a-number')"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric MAX_RERUNS fails with a clear error" {
	export MAX_RERUNS="one"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::MAX_RERUNS must be a non-negative integer (got 'one')"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: negative RUN_ATTEMPT fails validation" {
	export RUN_ATTEMPT="-1"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "RUN_ATTEMPT must be a non-negative integer"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric LOG_FETCH_ATTEMPTS fails with a clear error" {
	export LOG_FETCH_ATTEMPTS="lots"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_FETCH_ATTEMPTS must be a positive integer (got 'lots')"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: LOG_FETCH_ATTEMPTS of zero is rejected" {
	# Zero attempts would silently disable the log inspection the safety net is
	# built on, so it is a typo, not a valid opt-out.
	export LOG_FETCH_ATTEMPTS="0"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_FETCH_ATTEMPTS must be a positive integer (got '0')"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric LOG_FETCH_DELAY fails with a clear error" {
	export LOG_FETCH_DELAY="5s"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_FETCH_DELAY must be a non-negative integer (got '5s')"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
}

# =============================================================================
# Default signatures trigger a rerun of failed jobs
# =============================================================================

@test "rerun-on-infra-failure: 'Failed to resolve action download info' triggers rerun" {
	_mock_gh "job: Failed to resolve action download info. Error: Service Unavailable"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::notice::"
	assert_output --partial "Failed to resolve action download info"
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: 'The runner has received a shutdown signal' triggers rerun" {
	_mock_gh "The runner has received a shutdown signal."
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: an egress refusal is not an infra signature (#967)" {
	# Under harden-runner's block policy a missing allowlist entry fails the
	# same way every time; re-running it re-ran a publish run into the npm gate.
	local line
	for line in \
		"Error resolving allowed domain github.com" \
		"dial tcp 20.60.1.1:443: connect: connection refused" \
		"Error: connect ECONNREFUSED 127.0.0.1:443"; do
		_mock_gh "$line"
		run bash "$SCRIPT"
		assert_success
		assert_output --partial "No infra signature matched"
		[ ! -s "$RERUN_CALLS" ]
	done
}

@test "rerun-on-infra-failure: 'lost communication with the server' triggers rerun" {
	_mock_gh "The runner lost communication with the server."
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

# =============================================================================
# Cosign transient OIDC markers are built-in signatures (#719)
# =============================================================================

@test "rerun-on-infra-failure: a cosign ambient-OIDC failure triggers rerun via the defaults alone" {
	# No SIGNATURES input: the marker must be a built-in, otherwise a flake that
	# outlived the in-step retry leaves the run failed for a human.
	_mock_gh "Error: getting signer: fetching ambient OIDC credentials: none"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "fetching ambient OIDC credentials"
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

# Parity guard: every marker in the single source (scripts/ci/lib/cosign.sh) has
# to be matchable here, so adding a fourth marker there cannot leave this list
# stale.
@test "rerun-on-infra-failure: every cosign OIDC marker triggers rerun via the defaults" {
	local marker
	# shellcheck source=../../../../scripts/ci/lib/cosign.sh
	source "${PROJECT_ROOT}/scripts/ci/lib/cosign.sh"
	while IFS= read -r marker; do
		[[ -z "$marker" ]] && continue
		_mock_gh "cosign sign: Error: ${marker}: EOF"
		run bash "$SCRIPT"
		assert_success
		assert_output --partial "$marker"
		assert_equal "1" "$(_call_count "$RERUN_CALLS")"
	done <<<"$COSIGN_OIDC_TRANSIENT_MARKERS"
}

@test "rerun-on-infra-failure: signature matching stays case-sensitive" {
	# The in-step cosign retry matches case-insensitively because it only ever
	# sees one already-failed cosign invocation. The safety net decides whether
	# to re-run a whole workflow, so it keeps the stricter match and stores the
	# markers in the exact case cosign emits.
	_mock_gh "Error: FETCHING AMBIENT OIDC CREDENTIALS: none"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No infra signature matched"
	[ ! -s "$RERUN_CALLS" ]
}

# =============================================================================
# Rerun command shape
# =============================================================================

@test "rerun-on-infra-failure: rerun targets only failed jobs of the run" {
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_success
	run cat "$RERUN_CALLS"
	assert_output --partial "run rerun ${RUN_ID}"
	assert_output --partial "--failed"
}

# =============================================================================
# No signature match
# =============================================================================

@test "rerun-on-infra-failure: no matching signature exits 0 without rerun" {
	_mock_gh "assertion failed: expected 200 got 500 in tests/api_test.rs"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not re-running"
	[ ! -s "$RERUN_CALLS" ]
	run grep -c "No infra signature matched" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
}

# =============================================================================
# Attempt gating
# =============================================================================

@test "rerun-on-infra-failure: RUN_ATTEMPT above MAX_RERUNS skips without fetching logs" {
	export RUN_ATTEMPT="2"
	_mock_gh "Failed to resolve action download info"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "exceeds MAX_RERUNS=1"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
	[ ! -s "$SLEEP_CALLS" ]
}

@test "rerun-on-infra-failure: raised MAX_RERUNS allows a second attempt" {
	export RUN_ATTEMPT="2"
	export MAX_RERUNS="2"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: MAX_RERUNS=3 allows attempt 3 and skips attempt 4" {
	# #833 caller cap: three automatic re-runs, then hand off to a human.
	export MAX_RERUNS="3"
	_mock_gh "The runner has received a shutdown signal"

	export RUN_ATTEMPT="3"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"

	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	: >"$GITHUB_STEP_SUMMARY"
	export RUN_ATTEMPT="4"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "exceeds MAX_RERUNS=3"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
	run grep -F "Attempt 4 exceeds the max of 3 automatic re-run(s); leaving run ${RUN_ID} failed for a human." "$GITHUB_STEP_SUMMARY"
	assert_success
}

# =============================================================================
# Custom SIGNATURES extend the defaults
# =============================================================================

@test "rerun-on-infra-failure: custom SIGNATURES entry triggers rerun" {
	export SIGNATURES="No space left on device"
	_mock_gh "write /tmp/foo: No space left on device"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No space left on device"
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: defaults still match when SIGNATURES is set" {
	export SIGNATURES="No space left on device"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: custom SIGNATURES does not loosen matching" {
	export SIGNATURES="No space left on device"
	_mock_gh "a perfectly ordinary test failure"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
}

# =============================================================================
# Step summary on rerun
# =============================================================================

@test "rerun-on-infra-failure: writes a step summary naming the signature" {
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_success
	run grep -c "Auto re-run on infra failure" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
	run grep -c "Failed to resolve action download info" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
}

# =============================================================================
# Log-ingestion race: bounded refetch loop (#716)
# =============================================================================

@test "rerun-on-infra-failure: empty logs on the first attempt are refetched and matched" {
	_mock_gh_attempts "0:" "0:The runner has received a shutdown signal"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "The runner has received a shutdown signal"
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
	assert_equal "1" "$(_call_count "$SLEEP_CALLS")"
}

@test "rerun-on-infra-failure: whitespace-only logs are treated as unavailable and refetched" {
	_mock_gh_attempts "0:$(printf '\n\n   \n')" "0:lost communication with the server"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
}

@test "rerun-on-infra-failure: logs empty on every attempt reports inconclusive, not a real failure" {
	_mock_gh_attempts "0:"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::Inconclusive"
	[ ! -s "$RERUN_CALLS" ]
	assert_equal "5" "$(_call_count "$FETCH_CALLS")"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: logs unavailable."
	run grep -cF "The failure looks real" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

@test "rerun-on-infra-failure: inconclusive logs do not sleep after the final attempt" {
	_mock_gh_attempts "0:"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	# 5 attempts means 4 backoff waits, never a trailing one.
	assert_equal "4" "$(_call_count "$SLEEP_CALLS")"
}

@test "rerun-on-infra-failure: non-empty unmatched logs are not refetched" {
	_mock_gh_attempts "0:assertion failed: expected 200 got 500"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No infra signature matched"
	[ ! -s "$RERUN_CALLS" ]
	assert_equal "1" "$(_call_count "$FETCH_CALLS")"
	[ ! -s "$SLEEP_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "The failure looks real"
}

@test "rerun-on-infra-failure: matching logs on the first attempt never sleep" {
	_mock_gh_attempts "0:Failed to resolve action download info"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$FETCH_CALLS")"
	[ ! -s "$SLEEP_CALLS" ]
}

@test "rerun-on-infra-failure: a failing log fetch is retried within the loop" {
	_mock_gh_attempts "1:gh: could not read logs" "0:lost communication with the server"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
}

# An errored fetch is inconclusive, not fatal (#763). This job exists to react
# to someone else's red job; failing here adds a second red job and says nothing
# about the run it was inspecting. The common trigger is benign: a superseded
# run's log archive is already gone, and there is nothing to re-run.
@test "rerun-on-infra-failure: a log fetch failing on every attempt is inconclusive" {
	_mock_gh_attempts "1:gh: could not read logs"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "inconclusive, not re-running"
	[ ! -s "$RERUN_CALLS" ]
	assert_equal "5" "$(_call_count "$FETCH_CALLS")"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: log fetch errored"
	# Errored and empty must stay distinguishable for triage.
	run grep -cF "Inconclusive: logs unavailable" "$GITHUB_STEP_SUMMARY"
	assert_failure
	run grep -cF "The failure looks real" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

# The exact shape #763 was filed for: the triggering run was cancelled, so
# GitHub had already discarded the job's log archive.
@test "rerun-on-infra-failure: a superseded run whose logs are gone is not an error" {
	_mock_gh_attempts "1:log not found: 89765935589"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: log fetch errored"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "cancelled or superseded"
}

# The terminal classification comes from the last attempt only, so pin both
# orderings of a mixed error/empty run rather than leaving the semantics to
# uniform specs.
@test "rerun-on-infra-failure: an error followed by an empty payload is inconclusive" {
	export LOG_FETCH_ATTEMPTS="2"
	_mock_gh_attempts "1:gh: could not read logs" "0:"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "inconclusive, not re-running"
	[ ! -s "$RERUN_CALLS" ]
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: logs unavailable"
}

@test "rerun-on-infra-failure: an empty payload followed by an error is inconclusive" {
	export LOG_FETCH_ATTEMPTS="2"
	_mock_gh_attempts "0:" "1:gh: could not read logs"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "inconclusive, not re-running"
	[ ! -s "$RERUN_CALLS" ]
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
	# Terminal classification comes from the last attempt: errored, not empty.
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive: log fetch errored"
}

# =============================================================================
# Refetch bounds are configurable
# =============================================================================

@test "rerun-on-infra-failure: LOG_FETCH_ATTEMPTS caps the number of fetches" {
	export LOG_FETCH_ATTEMPTS="2"
	_mock_gh_attempts "0:"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
	assert_equal "1" "$(_call_count "$SLEEP_CALLS")"
	assert_output --partial "after 2 attempt(s)"
}

@test "rerun-on-infra-failure: LOG_FETCH_DELAY controls the backoff passed to sleep" {
	export LOG_FETCH_ATTEMPTS="2"
	export LOG_FETCH_DELAY="7"
	_mock_gh_attempts "0:" "0:Failed to resolve action download info"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	run cat "$SLEEP_CALLS"
	assert_output "7"
}

@test "rerun-on-infra-failure: LOG_FETCH_DELAY of zero skips sleeping entirely" {
	export LOG_FETCH_DELAY="0"
	_mock_gh_attempts "0:"
	_mock_sleep
	run bash "$SCRIPT"
	assert_success
	assert_equal "5" "$(_call_count "$FETCH_CALLS")"
	[ ! -s "$SLEEP_CALLS" ]
}

# =============================================================================
# Wall-clock bounds on every gh call (#743)
# =============================================================================

@test "rerun-on-infra-failure: non-numeric GH_CMD_TIMEOUT fails with a clear error" {
	export GH_CMD_TIMEOUT="90s"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::GH_CMD_TIMEOUT must be a positive integer (got '90s')"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: GH_CMD_TIMEOUT of zero is rejected" {
	# coreutils reads `timeout 0` as "no limit", which is precisely the
	# unbounded call this guard exists to forbid.
	export GH_CMD_TIMEOUT="0"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::GH_CMD_TIMEOUT must be a positive integer (got '0')"
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric LOG_FETCH_DEADLINE fails with a clear error" {
	export LOG_FETCH_DEADLINE="3m"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_FETCH_DEADLINE must be a positive integer (got '3m')"
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: LOG_FETCH_DEADLINE of zero is rejected" {
	export LOG_FETCH_DEADLINE="0"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_FETCH_DEADLINE must be a positive integer (got '0')"
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: a rerun that errors is reported, not a silent success" {
	_mock_gh "Failed to resolve action download info" "0" "1"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "gh run rerun exited 1"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "press re-run manually"
	refute_output --partial "::notice::"
}

@test "rerun-on-infra-failure: announces itself before any work" {
	# Ten minutes of total silence must not be a reachable state: the first
	# write happens before validation, sourcing or any subprocess, so "never
	# started" is always distinguishable from "started and stopped somewhere".
	export RUN_ATTEMPT="not-a-number"
	_mock_gh "irrelevant"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "rerun-on-infra-failure: starting (run=${RUN_ID} attempt=not-a-number)"
}

@test "rerun-on-infra-failure: logs the phase and payload size it is working on" {
	_mock_gh "The runner has received a shutdown signal"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Checking re-run eligibility for run ${RUN_ID}"
	assert_output --partial "Fetching failed-job logs of run ${RUN_ID} (attempt 1/5"
	assert_output --partial "bytes of failed-job logs for run ${RUN_ID}"
	assert_output --partial "Re-running the failed jobs of run ${RUN_ID}"
}

@test "rerun-on-infra-failure: non-numeric WATCHDOG_DEADLINE fails with a clear error" {
	export WATCHDOG_DEADLINE="soon"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::WATCHDOG_DEADLINE must be a positive integer (got 'soon')"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: WATCHDOG_DEADLINE of zero is rejected" {
	# Zero would mean "expired before starting", disabling the safety net.
	export WATCHDOG_DEADLINE="0"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "WATCHDOG_DEADLINE must be a positive integer"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric LOG_PROBE_TIME_BUDGET fails with a clear error" {
	export LOG_PROBE_TIME_BUDGET="a minute"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_PROBE_TIME_BUDGET must be a positive integer (got 'a minute')"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: LOG_PROBE_TIME_BUDGET of zero is rejected" {
	export LOG_PROBE_TIME_BUDGET="0"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_PROBE_TIME_BUDGET must be a positive integer (got '0')"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric LOG_PROBE_CMD_TIMEOUT fails with a clear error" {
	export LOG_PROBE_CMD_TIMEOUT="quick"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_PROBE_CMD_TIMEOUT must be a positive integer (got 'quick')"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: LOG_PROBE_CMD_TIMEOUT of zero is rejected" {
	export LOG_PROBE_CMD_TIMEOUT="0"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_PROBE_CMD_TIMEOUT must be a positive integer (got '0')"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric LOG_PROBE_MAX_JOBS fails with a clear error" {
	export LOG_PROBE_MAX_JOBS="five"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_PROBE_MAX_JOBS must be a non-negative integer (got 'five')"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: non-numeric LOG_PROBE_MAX_CALLS fails with a clear error" {
	export LOG_PROBE_MAX_CALLS="lots"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::LOG_PROBE_MAX_CALLS must be a non-negative integer (got 'lots')"
	[ ! -s "$RERUN_CALLS" ]
}

# =============================================================================
# Irreversible-step protection (#967)
# =============================================================================

@test "rerun-on-infra-failure: a protected workflow is never re-run even on a matching signature" {
	export PROTECTED_WORKFLOWS="publish-pypi-on-tag.yml"
	_mock_gh "The runner has received a shutdown signal"
	_run_meta 0 ".github/workflows/publish-pypi-on-tag.yml" "Publish - PyPI Production"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "protected workflow"
	[ ! -s "$RERUN_CALLS" ]
	# Decided before any log download.
	[ ! -s "$FETCH_CALLS" ]
	run grep -c "Protected workflow" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
}

@test "rerun-on-infra-failure: protected-workflows matches by path, basename or display name and tolerates commas" {
	local entry
	for entry in ".github/workflows/publish-pypi-on-tag.yml" "publish-pypi-on-tag.yml" "Publish - PyPI Production" "ci.yml, publish-pypi-on-tag.yml"; do
		export PROTECTED_WORKFLOWS="$entry"
		_mock_gh "The runner has received a shutdown signal"
		_run_meta 0 ".github/workflows/publish-pypi-on-tag.yml" "Publish - PyPI Production"
		run bash "$SCRIPT"
		assert_success
		[ ! -s "$RERUN_CALLS" ]
	done
}

@test "rerun-on-infra-failure: an unprotected workflow still re-runs with protected-workflows set" {
	export PROTECTED_WORKFLOWS=$'publish-pypi-on-tag.yml\npublish-npm.yml'
	_mock_gh "The runner has received a shutdown signal"
	_run_meta 0 ".github/workflows/ci.yml" "CI"
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: an unreadable run fails the protection check closed" {
	export PROTECTED_WORKFLOWS="publish-pypi-on-tag.yml"
	_mock_gh "The runner has received a shutdown signal"
	_run_meta 1 "" ""
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::"
	assert_output --partial "inconclusive"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: a failed job matching the default protected-job pattern blocks the rerun" {
	_mock_gh "The runner has received a shutdown signal"
	_failed_jobs 0 $'104386448873\tPublish to npm / Publish npm package set\t7'
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "irreversible steps"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
	run grep -c "Protected job(s): Publish to npm / Publish npm package set" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
}

@test "rerun-on-infra-failure: the default protected-job pattern covers publish, promote, release and upload, case-insensitively" {
	local name
	for name in "Promote Docker images to release tags" "UPLOAD to PyPI" "Create GitHub Release" "publish-set"; do
		_mock_gh "The runner has received a shutdown signal"
		_failed_jobs 0 "1	${name}	3"
		run bash "$SCRIPT"
		assert_success
		[ ! -s "$RERUN_CALLS" ]
	done
}

@test "rerun-on-infra-failure: a mix of protected and eligible failed jobs re-runs nothing and says why" {
	_mock_gh "The runner has received a shutdown signal"
	_failed_jobs 0 $'1\tPromote Docker images to release tags\t4' $'2\tBuild binaries\t2'
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	run grep -c "cannot exclude jobs" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
	run grep -c "Build binaries" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
}

@test "rerun-on-infra-failure: eligible failed jobs only still re-run on a signature" {
	_mock_gh "The runner has received a shutdown signal"
	_failed_jobs 0 $'1\tBuild binaries\t2' $'2\tTest (3.12)\t5'
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: an empty protected-job pattern disables the job guard" {
	export PROTECTED_JOB_PATTERN=""
	_mock_gh "The runner has received a shutdown signal"
	_failed_jobs 0 $'1\tPublish to npm\t7'
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
	# The guard was off, so the listing was never fetched.
	[ ! -s "$JOBS_CALLS" ]
}

@test "rerun-on-infra-failure: an unlistable job set fails the job guard closed" {
	_mock_gh "The runner has received a shutdown signal"
	_failed_jobs 1
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: an empty failed-jobs listing on a failed run is inconclusive, not consent" {
	_mock_gh "The runner has received a shutdown signal"
	_failed_jobs 0
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::"
	assert_output --partial "came back empty"
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$FETCH_CALLS" ]
}

@test "rerun-on-infra-failure: an invalid protected-job pattern fails with a clear error" {
	export PROTECTED_JOB_PATTERN="publish|("
	_mock_gh "The runner has received a shutdown signal"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "PROTECTED_JOB_PATTERN"
	[ ! -s "$RERUN_CALLS" ]
}

# =============================================================================
# Runner-acquisition failures (#967)
# =============================================================================

@test "rerun-on-infra-failure: a job that repeatedly failed to be acquired re-runs from its annotation" {
	_mock_sleep
	# The job never started, so the failed-job log is empty on every attempt.
	_mock_gh_attempts "0:"
	_failed_jobs 0 $'104349007496\ttest-compat / Python Compatibility (3.14)\t0'
	_job_annotations 104349007496 0 "The job repeatedly failed to be acquired (5 attempts)"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "runner acquisition failure"
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
	run grep -c "runner acquisition failure on job 104349007496" "$GITHUB_STEP_SUMMARY"
	assert_output "1"
}

@test "rerun-on-infra-failure: an acquisition failure next to a real failure is still re-run" {
	# One matrix leg lost its runner while another failed for real: the log
	# belongs to the real failure and matches nothing, the annotation does.
	_mock_gh "assertion failed: expected 200 got 500"
	_failed_jobs 0 $'1\ttest (3.12)\t9' $'2\ttest (3.14)\t0'
	_job_annotations 2 0 "The job repeatedly failed to be acquired (5 attempts)"
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: only zero-step failed jobs are checked for acquisition failures" {
	_mock_sleep
	_mock_gh_attempts "0:"
	_failed_jobs 0 $'1\ttest (3.12)\t9'
	_job_annotations 1 0 "The job repeatedly failed to be acquired (5 attempts)"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	run grep -c "check-runs/1/annotations" "$JOBS_CALLS"
	assert_output "0"
}

@test "rerun-on-infra-failure: an annotation without the acquisition wording stays inconclusive" {
	_mock_sleep
	_mock_gh_attempts "0:"
	_failed_jobs 0 $'1\ttest (3.14)\t0'
	_job_annotations 1 0 "Process completed with exit code 1."
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Inconclusive"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: ACQUISITION_MAX_JOBS=0 disables the annotation check" {
	export ACQUISITION_MAX_JOBS=0
	_mock_sleep
	_mock_gh_attempts "0:"
	_failed_jobs 0 $'1\ttest (3.14)\t0'
	_job_annotations 1 0 "The job repeatedly failed to be acquired (5 attempts)"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	run grep -c "annotations" "$JOBS_CALLS"
	assert_output "0"
}

@test "rerun-on-infra-failure: the acquisition check is capped by ACQUISITION_MAX_JOBS" {
	export ACQUISITION_MAX_JOBS=1
	_mock_sleep
	_mock_gh_attempts "0:"
	_failed_jobs 0 $'1\ttest (3.12)\t0' $'2\ttest (3.14)\t0'
	_job_annotations 2 0 "The job repeatedly failed to be acquired (5 attempts)"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	run grep -c "annotations" "$JOBS_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: a protected job is never re-run on an acquisition failure either" {
	_mock_sleep
	_mock_gh_attempts "0:"
	_failed_jobs 0 $'1\tPublish to npm\t0'
	_job_annotations 1 0 "The job repeatedly failed to be acquired (5 attempts)"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
}
