#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/rerun-on-infra-failure.sh (#463)

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/rerun-on-infra-failure.sh"
	export GITHUB_REPOSITORY="lgtm-hq/Rustume"
	export GH_TOKEN="test-token"
	export RUN_ID="29252857248"
	export RUN_ATTEMPT="1"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	export RERUN_CALLS="${BATS_TEST_TMPDIR}/rerun_calls"
	export FETCH_CALLS="${BATS_TEST_TMPDIR}/fetch_calls"
	export SLEEP_CALLS="${BATS_TEST_TMPDIR}/sleep_calls"
	unset MAX_RERUNS SIGNATURES LOG_FETCH_ATTEMPTS LOG_FETCH_DELAY
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Mock gh: serve the given failed-job logs for `run view --log-failed` and
# record `run rerun` invocations.
_mock_gh() {
	local logs="$1"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local logs_file="${mock_bin}/.failed_logs"
	printf '%s\n' "$logs" >"$logs_file"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		cat '${logs_file}'
		;;
	run\ rerun\ *)
		echo "\$*" >> '${RERUN_CALLS}'
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

# Mock gh with a per-attempt failed-log script (#716 ingestion race). Each
# argument describes one `run view --log-failed` attempt as
# "<exit-code>:<payload>"; attempts past the last spec repeat it. `run rerun`
# invocations are recorded as with _mock_gh.
_mock_gh_attempts() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local spec_dir="${BATS_TEST_TMPDIR}/gh_attempts"
	mkdir -p "$mock_bin" "$spec_dir"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"

	local count=0 spec
	for spec in "$@"; do
		count=$((count + 1))
		printf '%s' "${spec#*:}" >"${spec_dir}/${count}.log"
		printf '%s' "${spec%%:*}" >"${spec_dir}/${count}.status"
	done
	printf '%s' "$count" >"${spec_dir}/count"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
spec_dir='${spec_dir}'
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		attempt=\$(grep -c '' '${FETCH_CALLS}')
		count=\$(cat "\${spec_dir}/count")
		if [[ "\$attempt" -gt "\$count" ]]; then
			attempt="\$count"
		fi
		cat "\${spec_dir}/\${attempt}.log"
		exit "\$(cat "\${spec_dir}/\${attempt}.status")"
		;;
	run\ rerun\ *)
		echo "\$*" >> '${RERUN_CALLS}'
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

# Stub sleep so retry-loop tests record the backoff instead of waiting on it.
_mock_sleep() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	: >"$SLEEP_CALLS"

	cat >"${mock_bin}/sleep" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${SLEEP_CALLS}'
EOF
	chmod +x "${mock_bin}/sleep"
	export PATH="${mock_bin}:$PATH"
}

# Count lines in a recording file, tolerating a missing/empty file.
_call_count() {
	local file="$1"
	if [[ ! -s "$file" ]]; then
		echo 0
		return 0
	fi
	grep -c '' "$file"
}

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

@test "rerun-on-infra-failure: 'Error resolving allowed domain' triggers rerun" {
	_mock_gh "Error resolving allowed domain github.com"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
}

@test "rerun-on-infra-failure: 'lost communication with the server' triggers rerun" {
	_mock_gh "The runner lost communication with the server."
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "--failed" "$RERUN_CALLS"
	assert_output "1"
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
	_mock_gh_attempts "0:$(printf '\n\n   \n')" "0:Error resolving allowed domain github.com"
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

@test "rerun-on-infra-failure: a log fetch failing on every attempt fails loudly" {
	_mock_gh_attempts "1:gh: could not read logs"
	_mock_sleep
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Failed to fetch failed-job logs for run ${RUN_ID} after 5 attempt(s)"
	[ ! -s "$RERUN_CALLS" ]
	assert_equal "5" "$(_call_count "$FETCH_CALLS")"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "the last of 5 fetch attempt(s) failed"
	run grep -cF "The failure looks real" "$GITHUB_STEP_SUMMARY"
	assert_failure
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

@test "rerun-on-infra-failure: an empty payload followed by an error fails loudly" {
	export LOG_FETCH_ATTEMPTS="2"
	_mock_gh_attempts "0:" "1:gh: could not read logs"
	_mock_sleep
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Failed to fetch failed-job logs for run ${RUN_ID} after 2 attempt(s)"
	[ ! -s "$RERUN_CALLS" ]
	assert_equal "2" "$(_call_count "$FETCH_CALLS")"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "the last of 2 fetch attempt(s) failed"
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
