#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/bounded-run.sh (#1729)
#
# The perl watchdog is what bounds a command on a runner without coreutils
# timeout (the hosted macOS images), so most cases run with `timeout` and
# `gtimeout` hidden from PATH. Bounds are fractional seconds to keep the suite
# cheap under kcov; the callers pass whole seconds.

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	# A PATH with the tools these cases run and no timeout/gtimeout.
	export NO_TIMEOUT_PATH="${BATS_TEST_TMPDIR}/sysbin"
	mkdir -p "$NO_TIMEOUT_PATH"
	local tool src
	for tool in bash env sh perl sleep cat; do
		src="$(command -v "$tool")" || continue
		ln -sf "$src" "${NO_TIMEOUT_PATH}/${tool}"
	done
	# A marker unique to this test, so a process search cannot match others.
	export MARKER="31.$((RANDOM % 900 + 100))$$"
	unset TIMEOUT_BIN
}

teardown() {
	pkill -KILL -f "sleep ${MARKER}" 2>/dev/null || true
	restore_path
	teardown_temp_dir
}

# Run a snippet in a fresh bash with the lib sourced under the runners'
# shell options (`set -euo pipefail`, SIGPIPE ignored) and only
# NO_TIMEOUT_PATH on PATH. The snippet's exit status is printed as rc=N.
_run_fallback() {
	run env PATH="$NO_TIMEOUT_PATH" bash -c '
		set -euo pipefail
		trap "" PIPE
		source "$LIB_DIR/bounded-run.sh"
		bounded_run_resolve
		echo "mode=${BOUNDED_RUN_MODE}"
		rc=0
		'"$1"' || rc=$?
		echo "rc=${rc}"
	'
}

_no_marker_processes() {
	! pgrep -f "sleep ${MARKER}" >/dev/null 2>&1
}

# =============================================================================
# Fallback (no coreutils timeout on PATH)
# =============================================================================

@test "bounded_run: without timeout or gtimeout, perl is the bound" {
	_run_fallback 'bounded_run 5 1 sh -c "exit 0"'
	assert_success
	assert_line "mode=perl"
	assert_line "rc=0"
}

@test "bounded_run: a command that finishes in time keeps its status and output" {
	_run_fallback 'bounded_run 5 1 sh -c "echo out; echo err >&2; exit 3"'
	assert_success
	assert_line "out"
	assert_line "err"
	assert_line "rc=3"
}

@test "bounded_run: an overrunning command is terminated with status 124" {
	SECONDS=0
	_run_fallback 'bounded_run 0.3 5 sleep "$MARKER"'
	assert_success
	assert_line "rc=124"
	((SECONDS < 4)) || fail "the bound did not fire in time (${SECONDS}s)"
	_no_marker_processes || fail "the command outlived its bound"
}

@test "bounded_run: a command that ignores SIGTERM is killed after the grace with status 137" {
	SECONDS=0
	_run_fallback 'bounded_run 0.3 0.3 perl -e "\$SIG{TERM} = q(IGNORE); exec q(sleep), \$ENV{MARKER}"'
	assert_success
	assert_line "rc=137"
	((SECONDS < 4)) || fail "the kill did not follow the grace (${SECONDS}s)"
	_no_marker_processes || fail "the command outlived its bound"
}

@test "bounded_run: after the bound nothing in the command's process group lives on" {
	# The grandchild holds the output pipe: a leftover would hang `$(...)`.
	SECONDS=0
	_run_fallback 'out="$(bounded_run 0.3 5 sh -c "sleep $MARKER & sleep $MARKER")"'
	assert_success
	assert_line "rc=124"
	((SECONDS < 4)) || fail "the caller waited on a leftover process (${SECONDS}s)"
	_no_marker_processes || fail "a grandchild outlived the bound"
}

@test "bounded_run: a command that exits early returns at once and leaves no watchdog" {
	SECONDS=0
	# The marker rides along as an argument, so the watchdog's own command
	# line carries it too.
	_run_fallback 'bounded_run 30 10 sh -c "exit 0" "sleep $MARKER"'
	assert_success
	assert_line "rc=0"
	((SECONDS < 4)) || fail "an early exit waited for the bound (${SECONDS}s)"
	_no_marker_processes || fail "a watchdog outlived the command"
}

@test "bounded_run: the command inherits an ignored SIGPIPE" {
	_run_fallback 'bounded_run 5 1 perl -e "print \$SIG{PIPE} // q(DEFAULT), qq(\\n)"'
	assert_success
	assert_line "IGNORE"
	assert_line "rc=0"
}

@test "bounded_run: a command that cannot be run exits 127" {
	_run_fallback 'bounded_run 5 1 /nonexistent/command'
	assert_success
	assert_line "rc=127"
	assert_output --partial "bounded_run: /nonexistent/command:"
}

@test "bounded_run: a status of 124 from the command itself passes through" {
	_run_fallback 'bounded_run 5 1 sh -c "exit 124"'
	assert_success
	assert_line "rc=124"
}

@test "bounded_run: rejects a bound or grace that is not a positive number" {
	_run_fallback 'bounded_run 0 1 true'
	assert_line "rc=125"
	assert_output --partial "must be positive numbers"
	_run_fallback 'bounded_run 5 -1 true'
	assert_line "rc=125"
	_run_fallback 'bounded_run 5 1'
	assert_line "rc=125"
}

# =============================================================================
# Resolution
# =============================================================================

@test "bounded_run_resolve: fails loudly when no bound is available" {
	local bare="${BATS_TEST_TMPDIR}/bare"
	mkdir -p "$bare"
	ln -sf "$(command -v bash)" "${bare}/bash"
	run env PATH="$bare" bash -c 'source "$LIB_DIR/bounded-run.sh"; bounded_run_resolve'
	assert_failure
	assert_output --partial "Neither 'timeout' nor 'gtimeout' nor 'perl' is on PATH; no hard bound can be put on gh calls"
	run env PATH="$bare" bash -c 'source "$LIB_DIR/bounded-run.sh"; bounded_run 5 1 true'
	assert_equal "$status" 125
}

@test "bounded_run_resolve: an explicit TIMEOUT_BIN that is not on PATH fails loudly" {
	run env PATH="$NO_TIMEOUT_PATH" TIMEOUT_BIN=/nonexistent/timeout \
		bash -c 'source "$LIB_DIR/bounded-run.sh"; bounded_run_resolve'
	assert_failure
	assert_output --partial "TIMEOUT_BIN '/nonexistent/timeout' not found on PATH"
}

@test "bounded_run_resolve: prefers timeout, then gtimeout, over perl" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '#!/bin/sh\nexit 0\n' >"${mock_bin}/gtimeout"
	chmod +x "${mock_bin}/gtimeout"
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash -c \
		'source "$LIB_DIR/bounded-run.sh"; bounded_run_resolve; echo "${BOUNDED_RUN_MODE}:${BOUNDED_RUN_TIMEOUT_BIN}"'
	assert_success
	assert_output "timeout:gtimeout"
	cp "${mock_bin}/gtimeout" "${mock_bin}/timeout"
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash -c \
		'source "$LIB_DIR/bounded-run.sh"; bounded_run_resolve; echo "${BOUNDED_RUN_MODE}:${BOUNDED_RUN_TIMEOUT_BIN}"'
	assert_output "timeout:timeout"
}

# =============================================================================
# With coreutils timeout present (unchanged behaviour)
# =============================================================================

@test "bounded_run: with timeout on PATH the call is timeout --kill-after=<grace>s <seconds> <command>" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/timeout" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >'${BATS_TEST_TMPDIR}/timeout_argv'
exit 7
EOF
	chmod +x "${mock_bin}/timeout"
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash -c \
		'source "$LIB_DIR/bounded-run.sh"; bounded_run 30 10 gh api -X GET "a b"'
	assert_equal "$status" 7
	assert_equal "$(cat "${BATS_TEST_TMPDIR}/timeout_argv")" "--kill-after=10s 30 gh api -X GET a b"
}

@test "bounded_run: a real coreutils timeout gives the same statuses as the fallback" {
	local real="" candidate
	for candidate in gtimeout timeout; do
		if command -v "$candidate" >/dev/null 2>&1 &&
			"$candidate" --version 2>/dev/null | grep -q coreutils; then
			real="$(command -v "$candidate")"
			break
		fi
	done
	[[ -n "$real" ]] || skip "no coreutils timeout on this host"
	export TIMEOUT_BIN="$real"
	_run_fallback 'bounded_run 0.3 5 sleep "$MARKER"'
	assert_line "mode=timeout"
	assert_line "rc=124"
	_run_fallback 'bounded_run 0.3 0.3 perl -e "\$SIG{TERM} = q(IGNORE); exec q(sleep), \$ENV{MARKER}"'
	assert_line "rc=137"
	_run_fallback 'bounded_run 5 1 sh -c "exit 3"'
	assert_line "rc=3"
}
