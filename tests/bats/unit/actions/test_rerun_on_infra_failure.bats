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
	unset LOG_FETCH_DEADLINE GH_CMD_TIMEOUT TIMEOUT_BIN
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

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		cat '${logs_file}'
		;;
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
