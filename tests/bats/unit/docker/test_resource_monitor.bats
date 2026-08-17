#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/docker/resource-monitor.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/docker/resource-monitor.sh"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner-temp"
	mkdir -p "$RUNNER_TEMP"
	unset RESOURCE_MONITOR_MAX_SAMPLES
	unset RESOURCE_MONITOR_INTERVAL
	unset RESOURCE_MONITOR_LOG
	unset RESOURCE_MONITOR_PID_FILE
	_stop_monitor || true
}

teardown() {
	_stop_monitor || true
	restore_path
	teardown_temp_dir
}

_stop_monitor() {
	local pid_file="${RESOURCE_MONITOR_PID_FILE:-${RUNNER_TEMP:-}/resource-monitor.pid}"
	local log_file="${RESOURCE_MONITOR_LOG:-${RUNNER_TEMP:-}/resource-monitor.log}"
	if [[ -n "${pid_file}" && -f "$pid_file" ]]; then
		local pid
		pid="$(cat "$pid_file" 2>/dev/null || true)"
		if [[ -n "${pid:-}" ]]; then
			pkill -P "$pid" 2>/dev/null || true
			kill -9 "$pid" 2>/dev/null || true
		fi
		rm -f "$pid_file"
	fi
	# kcov waits on leftover samplers; reap by the log path in the child argv.
	if [[ -n "${log_file}" ]]; then
		pkill -f "$log_file" 2>/dev/null || true
	fi
}

_mock_free_df_date() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/date" <<'EOF'
#!/usr/bin/env bash
echo "2026-08-15T09:00:00Z"
exit 0
EOF
	cat >"${mock_bin}/free" <<'EOF'
#!/usr/bin/env bash
echo "               total        used        free      shared  buff/cache   available"
echo "Mem:            16000        4000       12000           0        2000       13000"
exit 0
EOF
	cat >"${mock_bin}/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/root        84G   40G   44G  48% /"
exit 0
EOF
	chmod +x "${mock_bin}/date" "${mock_bin}/free" "${mock_bin}/df"
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

_wait_for_sample() {
	local log_file="$1"
	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
		if [[ -f "$log_file" ]] &&
			grep -qF "[resource-monitor] 2026-08-15T09:00:00Z" "$log_file" &&
			grep -qE "Mem:|free:" "$log_file" &&
			grep -qE "/dev/root|df:" "$log_file"; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

_assert_no_sampler_for() {
	local marker="$1"
	local leftover
	leftover="$(pgrep -f "$marker" || true)"
	assert_equal "" "$leftover"
}

@test "resource-monitor.sh: script is executable" {
	[[ -x "$SCRIPT" ]]
}

@test "resource-monitor.sh: rejects missing subcommand" {
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Usage:"
}

@test "resource-monitor.sh: rejects unknown subcommand" {
	run bash "$SCRIPT" status
	assert_failure
	assert_output --partial "Unknown subcommand: status"
}

@test "resource-monitor.sh: start requires RUNNER_TEMP" {
	run env -u RUNNER_TEMP bash "$SCRIPT" start
	assert_failure
	assert_output --partial "RUNNER_TEMP is required"
}

@test "resource-monitor.sh: start rejects invalid interval" {
	run env RESOURCE_MONITOR_INTERVAL=0 bash "$SCRIPT" start
	assert_failure
	assert_output --partial "RESOURCE_MONITOR_INTERVAL must be a positive integer"
}

@test "resource-monitor.sh: start appends timestamp + free + df and flushes" {
	_mock_free_df_date
	export RESOURCE_MONITOR_INTERVAL=30
	export RESOURCE_MONITOR_MAX_SAMPLES=1

	run bash "$SCRIPT" start
	assert_success
	assert_output --partial "Started resource monitor"

	local log_file="${RUNNER_TEMP}/resource-monitor.log"
	_wait_for_sample "$log_file"
	assert_file_exists "$log_file"
	assert_file_contains_literal "$log_file" "[resource-monitor] 2026-08-15T09:00:00Z"
	assert_file_contains_literal "$log_file" "Mem:"
	assert_file_contains_literal "$log_file" "/dev/root"
}

@test "resource-monitor.sh: start writes a [resource-monitor] line to stdout" {
	_mock_free_df_date
	export RESOURCE_MONITOR_INTERVAL=30
	export RESOURCE_MONITOR_MAX_SAMPLES=1

	run bash "$SCRIPT" start
	assert_success
	assert_output --partial "[resource-monitor]"
	assert_output --partial "Mem:"
	assert_output --partial "/dev/root"
}

@test "resource-monitor.sh: start is idempotent when the loop is running" {
	_mock_free_df_date
	# Finite loop so a missed teardown cannot pin kcov until the suite timeout.
	# Redirect to a file (not `run`): the live sampler keeps stdout open, and
	# bats `run` waits for every writer to close.
	export RESOURCE_MONITOR_INTERVAL=1
	export RESOURCE_MONITOR_MAX_SAMPLES=30

	local start_out="${BATS_TEST_TMPDIR}/start.out"
	local again_out="${BATS_TEST_TMPDIR}/start-again.out"
	bash "$SCRIPT" start >"$start_out" 2>&1
	assert_equal "0" "$?"
	assert_file_contains_literal "$start_out" "Started resource monitor"
	local first_pid
	first_pid="$(cat "${RUNNER_TEMP}/resource-monitor.pid")"

	bash "$SCRIPT" start >"$again_out" 2>&1
	assert_equal "0" "$?"
	assert_file_contains_literal "$again_out" "already running"
	assert_equal "$first_pid" "$(cat "${RUNNER_TEMP}/resource-monitor.pid")"
}

@test "resource-monitor.sh: later samples still append after stdout is closed" {
	_mock_free_df_date
	export RESOURCE_MONITOR_INTERVAL=1
	export RESOURCE_MONITOR_MAX_SAMPLES=4

	local err_file="${BATS_TEST_TMPDIR}/start.err"
	# Process substitution reader exits immediately so later prints EPIPE.
	# File append must still land (stdout failure is best-effort).
	bash "$SCRIPT" start > >(true) 2>"$err_file"
	assert_equal "0" "$?"
	assert_file_contains_literal "$err_file" "Started resource monitor"

	local log_file="${RUNNER_TEMP}/resource-monitor.log"
	_wait_for_sample "$log_file"

	# One extra append can land before SIGPIPE kills an untrapped sampler.
	# Require three prefixed timestamps so the loop outlived the closed pipe.
	local i sample_count
	sample_count=0
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
		sample_count="$(grep -cF "[resource-monitor] 2026-08-15T09:00:00Z" "$log_file" || true)"
		if [[ "$sample_count" -ge 3 ]]; then
			break
		fi
		sleep 0.2
	done
	[[ "$sample_count" -ge 3 ]]
}

@test "resource-monitor.sh: dump prints last 100 lines" {
	local log_file="${RUNNER_TEMP}/resource-monitor.log"
	local i
	: >"$log_file"
	for i in $(seq 1 120); do
		echo "sample-line-${i}" >>"$log_file"
	done

	run bash "$SCRIPT" dump
	assert_success
	assert_output --partial "=== Resource monitor (last 100 lines) ==="
	assert_output --partial "sample-line-21"
	assert_output --partial "sample-line-120"
	refute_output --partial "sample-line-20"
}

@test "resource-monitor.sh: dump succeeds when the log is missing" {
	run bash "$SCRIPT" dump
	assert_success
	assert_output --partial "No resource monitor log found"
}

@test "resource-monitor.sh: start fails when log parent is unavailable" {
	local blocker="${BATS_TEST_TMPDIR}/unavailable-log-parent"
	touch "$blocker"
	export RESOURCE_MONITOR_LOG="${blocker}/monitor.log"

	run bash "$SCRIPT" start
	assert_failure
	assert_output --partial "Cannot create log parent directory"
	_assert_no_sampler_for "${blocker}/monitor.log"
}

@test "resource-monitor.sh: start fails when PID-file parent is unavailable" {
	local blocker="${BATS_TEST_TMPDIR}/unavailable-pid-parent"
	touch "$blocker"
	export RESOURCE_MONITOR_PID_FILE="${blocker}/monitor.pid"

	run bash "$SCRIPT" start
	assert_failure
	assert_output --partial "Cannot create PID file parent directory"
	_assert_no_sampler_for "${blocker}/monitor.pid"
	_assert_no_sampler_for "${RUNNER_TEMP}/resource-monitor.log"
}
