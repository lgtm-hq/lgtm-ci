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
	unset MAX_RERUNS SIGNATURES
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

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
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
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "exceeds MAX_RERUNS=1"
	[ ! -s "$RERUN_CALLS" ]
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
