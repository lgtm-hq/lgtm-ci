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
	export API_CALLS="${BATS_TEST_TMPDIR}/api_calls"
	export PROBE_DIR="${BATS_TEST_TMPDIR}/gh_probe"
	unset MAX_RERUNS SIGNATURES LOG_FETCH_ATTEMPTS LOG_FETCH_DELAY
	unset LOG_FETCH_DEADLINE GH_CMD_TIMEOUT TIMEOUT_BIN
	unset LOG_PROBE_MAX_JOBS LOG_PROBE_MAX_CALLS LOG_PROBE_CMD_TIMEOUT
	unset LOG_PROBE_TIME_BUDGET
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Portable stand-in for coreutils `timeout` (#743). macOS ships no `timeout`, so
# depending on the real binary would make this suite pass on CI and fail
# locally; stubbing it unconditionally keeps both identical. It implements only
# the shape the script uses — flags, then "<seconds> cmd ..." — exits 124 when
# the bound trips, and blocks on a fifo rather than `sleep`, which this suite
# also stubs.
_mock_timeout() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${TIMEOUT_CALLS:-}" ]]; then
	echo "$*" >>"$TIMEOUT_CALLS"
fi
while [[ "$1" == -* ]]; do
	case "$1" in
	-k | -s) shift 2 ;;
	*) shift ;;
	esac
done
limit="$1"
shift

fifo="$(mktemp -u "${TMPDIR:-/tmp}/timeout-stub.XXXXXX")"
mkfifo "$fifo"
exec 9<>"$fifo"
rm -f "$fifo"

"$@" &
child=$!
(read -r -t "$limit" -u 9 _ || kill -TERM "$child" 2>/dev/null) &
watchdog=$!

status=0
wait "$child" || status=$?
printf 'done\n' >&9
wait "$watchdog" 2>/dev/null || true

# A command killed by the watchdog reports a signal status; report it the way
# coreutils timeout does.
if ((status > 128)); then
	exit 124
fi
exit "$status"
EOF
	chmod +x "${mock_bin}/timeout"
}

# Shell snippet for a gh mock that blocks for "$hang_for" seconds without
# sleeping, so the wrapping timeout is what ends it.
_gh_hang_snippet() {
	cat <<'EOF'
	hang_fifo="$(mktemp -u "${TMPDIR:-/tmp}/gh-hang.XXXXXX")"
	mkfifo "$hang_fifo"
	exec 8<>"$hang_fifo"
	rm -f "$hang_fifo"
	read -r -t "$hang_for" -u 8 _ || true
	exit 0
EOF
}

# Fixture store for the #794 ingestion probe: the attempt-jobs listing and the
# raw per-job logs the gh stub serves for `gh api`. Reset by every gh mock, so
# a test that says nothing about the probe still gets a well-defined, quiet
# stub (an empty listing) instead of an "unexpected gh call" error.
_init_probe_dir() {
	rm -rf "$PROBE_DIR"
	mkdir -p "$PROBE_DIR"
	: >"${PROBE_DIR}/listing"
	printf '0' >"${PROBE_DIR}/listing.status"
	: >"${PROBE_DIR}/joblog.default"
	printf '0' >"${PROBE_DIR}/joblog.default.status"
	: >"$API_CALLS"
}

# Set the attempt-jobs listing the stub returns: "<exit-code>" then zero or more
# "<job-id>	<conclusion>	<completed-at>" rows.
_probe_listing() {
	local status="$1" row
	shift
	printf '%s' "$status" >"${PROBE_DIR}/listing.status"
	: >"${PROBE_DIR}/listing"
	for row in "$@"; do
		printf '%s\n' "$row" >>"${PROBE_DIR}/listing"
	done
}

# Set the raw log the stub serves for one job id (or "default" for all others):
# _probe_job_log <job-id|default> <exit-code> <payload>, or exit-code "hang"
# with the payload as a number of seconds to block for, so the probe's own
# timeout is what ends the call.
_probe_job_log() {
	local job_id="$1" status="$2" payload="$3"
	printf '%s' "$payload" >"${PROBE_DIR}/joblog.${job_id}"
	printf '%s' "$status" >"${PROBE_DIR}/joblog.${job_id}.status"
}

# `gh api` branches for the mock, serving the probe fixtures and recording every
# call so tests can assert on the flags used and on the call count.
_gh_api_case() {
	cat <<EOF
	"api "*"/attempts/"*"/jobs"*)
		echo "\$*" >> '${API_CALLS}'
		cat '${PROBE_DIR}/listing'
		exit "\$(cat '${PROBE_DIR}/listing.status')"
		;;
	"api "*"/actions/jobs/"*"/logs"*)
		echo "\$*" >> '${API_CALLS}'
		api_args="\$*"
		job_id="\${api_args##*/actions/jobs/}"
		job_id="\${job_id%%/logs*}"
		job_file='${PROBE_DIR}'"/joblog.\${job_id}"
		if [[ ! -f "\$job_file" ]]; then
			job_file='${PROBE_DIR}/joblog.default'
		fi
		job_status="\$(cat "\${job_file}.status")"
		if [[ "\$job_status" == "hang" ]]; then
			hang_for="\$(cat "\$job_file")"
$(_gh_hang_snippet)
		fi
		cat "\$job_file"
		exit "\$job_status"
		;;
EOF
}

# Mock gh: serve the given failed-job logs for `run view --log-failed` and
# record `run rerun` invocations. Optional arguments make `run rerun` block for
# that many seconds, and exit with that status.
_mock_gh() {
	local logs="$1" rerun_hang="${2:-0}" rerun_status="${3:-0}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local logs_file="${mock_bin}/.failed_logs"
	printf '%s\n' "$logs" >"$logs_file"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	_init_probe_dir

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		cat '${logs_file}'
		;;
$(_gh_api_case)
	run\ rerun\ *)
		echo "\$*" >> '${RERUN_CALLS}'
		hang_for='${rerun_hang}'
		if [[ "\$hang_for" != "0" ]]; then
$(_gh_hang_snippet)
		fi
		exit '${rerun_status}'
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	_mock_timeout
	export PATH="${mock_bin}:$PATH"
}

# Mock gh with a per-attempt failed-log script (#716 ingestion race). Each
# argument describes one `run view --log-failed` attempt as
# "<exit-code>:<payload>", or as "hang:<seconds>" to make that attempt block
# until the wrapping timeout kills it (#743); attempts past the last spec repeat
# it. `run rerun` invocations are recorded as with _mock_gh.
_mock_gh_attempts() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local spec_dir="${BATS_TEST_TMPDIR}/gh_attempts"
	mkdir -p "$mock_bin" "$spec_dir"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	_init_probe_dir

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
		status="\$(cat "\${spec_dir}/\${attempt}.status")"
		if [[ "\$status" == "hang" ]]; then
			hang_for="\$(cat "\${spec_dir}/\${attempt}.log")"
$(_gh_hang_snippet)
		fi
		cat "\${spec_dir}/\${attempt}.log"
		exit "\$status"
		;;
$(_gh_api_case)
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
	_mock_timeout
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

@test "rerun-on-infra-failure: a missing timeout binary fails loudly instead of running unbounded" {
	export TIMEOUT_BIN="lgtm-ci-no-such-timeout"
	_mock_gh "Failed to resolve action download info"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "TIMEOUT_BIN 'lgtm-ci-no-such-timeout' not found on PATH"
	[ ! -s "$FETCH_CALLS" ]
	[ ! -s "$RERUN_CALLS" ]
}

# A PATH holding only what the script needs, so `timeout` can be made genuinely
# absent. Restricting PATH is the only way to test the fallback on a Linux
# runner, where /usr/bin/timeout cannot be hidden any other way.
_minimal_path_dir() {
	local dir="${BATS_TEST_TMPDIR}/sysbin" tool src
	mkdir -p "$dir"
	for tool in bash env cat chmod dirname grep kill mkfifo mktemp rm sleep; do
		src="$(command -v "$tool" 2>/dev/null)" || continue
		ln -sf "$src" "${dir}/${tool}"
	done
	printf '%s\n' "$dir"
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
	assert_equal "2" "$(_call_count "$TIMEOUT_CALLS")"
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
	assert_equal "2" "$(_call_count "$TIMEOUT_CALLS")"
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

@test "rerun-on-infra-failure: a rerun that errors is reported, not a silent success" {
	_mock_gh "Failed to resolve action download info" "0" "1"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "gh run rerun exited 1"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "press re-run manually"
	refute_output --partial "::notice::"
}

# =============================================================================
# Silent-hang regression and the script-level watchdog (#776)
# =============================================================================

# Mock gh serving a large, whitespace-dense failed-job payload followed by a
# transient signature. Whitespace density is the point: the #776 hang was
# `${logs//[[:space:]]/}`, whose cost is O(length x matches), so it is the
# proportion of whitespace — not the size alone — that made a real failed-job
# log take minutes to classify.
_mock_gh_large_log() {
	local bytes="$1" trailer="$2"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	_init_probe_dir

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		yes '	shell-tests	2026-07-26T12:45:31.1234567Z ok 1 a test name with spaces' | head -c '${bytes}'
		printf '\n%s\n' '${trailer}'
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
	_mock_timeout
	export PATH="${mock_bin}:$PATH"
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
	run grep -c "^eof=1$" "$probe"
	assert_output "2"
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
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "\`55501\` (failure)"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "available"
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
