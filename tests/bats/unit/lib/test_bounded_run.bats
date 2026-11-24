#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/bounded-run.sh (#1729)
#
# The perl watchdog is what bounds a command on a runner without coreutils
# timeout (the hosted macOS images), so most cases run with `timeout` and
# `gtimeout` hidden from PATH. Bounds are fractional seconds to keep the suite
# cheap under kcov; the callers pass whole seconds.
#
# Code under test runs from a script file, never `bash -c`: kcov traces
# nested shells with a PS4 that reads BASH_SOURCE, which a `-c` shell lacks,
# and the runner keeps `set -u` like the callers.

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	# Resolved before any test narrows PATH; a missing pgrep would make every
	# "nothing left running" check pass without looking.
	PGREP="$(command -v pgrep)" || fail "pgrep is required to check for leftover processes"
	export PGREP
	# A PATH with the tools these cases run and no timeout/gtimeout.
	export NO_TIMEOUT_PATH="${BATS_TEST_TMPDIR}/sysbin"
	mkdir -p "$NO_TIMEOUT_PATH"
	local tool src
	for tool in bash env sh perl sleep cat touch mv kill; do
		src="$(command -v "$tool")" || continue
		[[ "$src" == /* ]] || continue
		ln -sf "$src" "${NO_TIMEOUT_PATH}/${tool}"
	done
	# A marker unique to this test, so a process search cannot match others.
	export MARKER="31.$((RANDOM % 900 + 100))$$"
	export READY_FILE="${BATS_TEST_TMPDIR}/ready"
	export STARTED_FILE="${BATS_TEST_TMPDIR}/started"
	unset TIMEOUT_BIN BOUNDED_RUN_FAULT
}

teardown() {
	local pids
	pids="$("$PGREP" -f "sleep ${MARKER}" 2>/dev/null)" || pids=""
	if [[ -n "$pids" ]]; then
		# shellcheck disable=SC2086 # one pid per word
		kill -KILL $pids 2>/dev/null || true
	fi
	restore_path
	teardown_temp_dir
}

# Run a snippet in a fresh bash, from a script file, with the lib sourced
# under the runners' shell options (`set -euo pipefail`, SIGPIPE ignored)
# and only NO_TIMEOUT_PATH on PATH. Prints mode=<mode> after resolving and
# the snippet's exit status as rc=N. Extra `env` assignments follow the
# snippet. _write_runner only writes RUNNER, for cases that pick their own PATH.
RUNNER_NAME="runner.sh"
_write_runner() {
	RUNNER="${BATS_TEST_TMPDIR}/${RUNNER_NAME}"
	{
		printf '%s\n' 'set -euo pipefail' "trap '' PIPE" \
			'source "$LIB_DIR/bounded-run.sh"' \
			'bounded_run_resolve' 'echo "mode=${BOUNDED_RUN_MODE}"' 'rc=0'
		printf '%s || rc=$?\n' "$1"
		printf '%s\n' 'echo "rc=${rc}"'
	} >"$RUNNER"
}

_run_fallback() {
	_write_runner "$1"
	shift
	run env PATH="$NO_TIMEOUT_PATH" "$@" bash "$RUNNER"
}

# Fail when a process carrying MARKER is still running; tell "none" apart
# from a pgrep that could not look.
_assert_no_marked_processes() {
	local found rc=0
	found="$("$PGREP" -f "sleep ${MARKER}" 2>&1)" || rc=$?
	case "$rc" in
	0) fail "left running after the call: ${found}" ;;
	1) return 0 ;;
	*) fail "pgrep could not inspect processes (exit ${rc}): ${found}" ;;
	esac
}

# A command that ignores SIGTERM. It writes READY_FILE (its parent's pid:
# the watchdog) only once TERM is ignored, then sleeps under MARKER.
# shellcheck disable=SC2016 # perl source, expanded by perl
TERM_IGNORING='perl -e "\$SIG{TERM} = q(IGNORE); open my \$f, q(>), qq(\$ENV{READY_FILE}.tmp) or die; print \$f getppid(); close \$f; rename qq(\$ENV{READY_FILE}.tmp), \$ENV{READY_FILE} or die; exec q(sleep), \$ENV{MARKER}"'

# Run the TERM-ignoring command under a bound, lengthening the bound until
# the command was ready (TERM ignored) before the bound fired, so a slow
# runner cannot turn the 137 case into a 124 one.
_run_term_ignoring() {
	local bound
	for bound in 0.3 1 3 9; do
		rm -f "$READY_FILE"
		_run_fallback "bounded_run ${bound} 0.3 ${TERM_IGNORING}"
		[[ -s "$READY_FILE" ]] && return 0
	done
	fail "the TERM-ignoring command never became ready within a 9s bound"
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
	((SECONDS < 10)) || fail "the bound did not fire in time (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a command that ignores SIGTERM is killed after the grace with status 137" {
	SECONDS=0
	_run_term_ignoring
	assert_success
	assert_line "rc=137"
	((SECONDS < 20)) || fail "the kill did not follow the grace (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: after the bound nothing in the command's process group lives on" {
	# The grandchild holds the output pipe: a leftover would hang `$(...)`.
	SECONDS=0
	_run_fallback 'out="$(bounded_run 0.3 5 sh -c "sleep $MARKER & sleep $MARKER")"'
	assert_success
	assert_line "rc=124"
	((SECONDS < 10)) || fail "the caller waited on a leftover process (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a command that exits early with a background child returns at once" {
	# The leader exits before the bound; its child still holds the output pipe
	# and would keep `$(...)` open for the whole sleep.
	SECONDS=0
	_run_fallback 'out="$(bounded_run 30 5 sh -c "sleep $MARKER & exit 3")"'
	assert_success
	assert_line "rc=3"
	((SECONDS < 10)) || fail "the caller waited on the leader's background child (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a command that exits early returns at once and leaves no watchdog" {
	# The marker rides along as an argument, so the watchdog's own command
	# line carries it too.
	SECONDS=0
	_run_fallback 'bounded_run 30 10 sh -c "exit 0" "sleep $MARKER"'
	assert_success
	assert_line "rc=0"
	((SECONDS < 10)) || fail "an early exit waited for the bound (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a TERM sent to the watchdog is passed on and starts the SIGKILL grace" {
	# The command ignores TERM; without the grace it would live to the 30s
	# bound. It reports the watchdog's pid once it is ready.
	SECONDS=0
	# The sender gives up after 10s and holds none of the runner's output.
	_run_fallback "( i=0; until [ -s \"\$READY_FILE\" ] || [ \$i -ge 200 ]; do sleep 0.05; i=\$((i + 1)); done; kill -TERM \"\$(cat \"\$READY_FILE\")\" ) </dev/null >/dev/null 2>&1 & bounded_run 30 0.3 ${TERM_IGNORING}"
	assert_success
	assert_line "rc=137"
	((SECONDS < 10)) || fail "the forwarded TERM did not start the grace (${SECONDS}s)"
	_assert_no_marked_processes
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

@test "bounded_run: the command's own status passes through, signals as 128+N" {
	_run_fallback 'bounded_run 5 1 sh -c "exit 124"'
	assert_line "rc=124"
	_run_fallback 'bounded_run 5 1 sh -c "kill -TERM \$\$"'
	assert_line "rc=143"
}

# =============================================================================
# Bounds the watchdog cannot honour are refused or capped, never dropped
# =============================================================================

@test "bounded_run: refuses a bound or grace below 0.001 or not a number, before running anything" {
	local args
	for args in "0 1" "5 -1" "0.0009 1" "0.0000001 1" "0.00000000001 1" "1 0.0000001" "abc 1" "1e3 1" ". 1"; do
		_run_fallback "bounded_run ${args} touch \"\$STARTED_FILE\""
		assert_line "rc=125"
		assert_output --partial "must be decimal numbers of at least 0.001"
		[[ ! -e "$STARTED_FILE" ]] || fail "bounded_run ${args} ran the command"
	done
	_run_fallback 'bounded_run 5 1'
	assert_line "rc=125"
}

@test "bounded_run: a bound or grace above the interval timer's limit is capped, not dropped" {
	_run_fallback 'bounded_run 200000000 1 sh -c "exit 0"'
	assert_line "rc=0"
	refute_output --partial "could not arm"
	_run_fallback 'bounded_run 9999999999999999999999999999999999999 9999999999999999999999999999999999999 sh -c "exit 0"'
	assert_line "rc=0"
	refute_output --partial "could not arm"
}

@test "bounded_run: a bound timer that cannot be armed kills the command and exits 125" {
	SECONDS=0
	_run_fallback 'bounded_run 30 1 sh -c "touch \"\$STARTED_FILE\"; exec sleep $MARKER"' BOUNDED_RUN_FAULT=bound
	assert_line "rc=125"
	assert_output --partial "could not arm the bound timer"
	((SECONDS < 10)) || fail "the command ran on without a bound (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a grace timer that cannot be armed kills at once and exits 125" {
	SECONDS=0
	local bound
	for bound in 0.3 1 3 9; do
		rm -f "$READY_FILE"
		_run_fallback "bounded_run ${bound} 30 ${TERM_IGNORING}" BOUNDED_RUN_FAULT=grace
		[[ -s "$READY_FILE" ]] && break
	done
	assert_line "rc=125"
	assert_output --partial "could not arm the grace timer"
	((SECONDS < 20)) || fail "a TERM-ignoring command outlived a failed grace (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a command that cannot get its own process group is not run" {
	_run_fallback 'bounded_run 5 1 touch "$STARTED_FILE"' BOUNDED_RUN_FAULT=setpgrp
	assert_line "rc=125"
	assert_output --partial "no process group of its own"
	[[ ! -e "$STARTED_FILE" ]] || fail "the command ran outside its own process group"
}

# =============================================================================
# The environment cannot switch the watchdog off
# =============================================================================

@test "bounded_run: a PERL5OPT preload that disarms the timer has no effect" {
	local poison="${BATS_TEST_TMPDIR}/poison"
	mkdir -p "$poison"
	cat >"${poison}/BoundedRunPoison.pm" <<'EOF'
package BoundedRunPoison;
use Time::HiRes ();
no warnings 'redefine';
*Time::HiRes::setitimer = sub { return (0, 0) };
1;
EOF
	SECONDS=0
	_run_fallback 'bounded_run 0.3 5 sleep "$MARKER"' \
		PERL5LIB="$poison" PERLLIB="$poison" PERL5OPT=-MBoundedRunPoison PERL_SIGNALS=unsafe
	assert_line "mode=perl"
	assert_line "rc=124"
	((SECONDS < 10)) || fail "the preload disarmed the bound (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a readonly PERL5OPT preload cannot disarm the timer either" {
	# A shell that sources the helper may hold the variables readonly, where
	# unset fails. BASH_ENV makes the runner's shell do that before anything.
	local poison="${BATS_TEST_TMPDIR}/poison"
	mkdir -p "$poison"
	cat >"${poison}/BoundedRunPoison.pm" <<'EOF'
package BoundedRunPoison;
use Time::HiRes ();
no warnings 'redefine';
*Time::HiRes::setitimer = sub { return (0, 0) };
1;
EOF
	printf '%s\n' 'readonly PERL5OPT PERL5LIB' >"${BATS_TEST_TMPDIR}/readonly.env"
	SECONDS=0
	_run_fallback 'bounded_run 0.3 5 sleep "$MARKER"' \
		BASH_ENV="${BATS_TEST_TMPDIR}/readonly.env" \
		PERL5LIB="$poison" PERL5OPT=-MBoundedRunPoison
	assert_line "mode=perl"
	assert_line "rc=124"
	((SECONDS < 10)) || fail "the readonly preload disarmed the bound (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: the command runs without the caller's PERL* variables" {
	_run_fallback 'bounded_run 5 1 sh -c "echo opt=\${PERL5OPT-unset} db=\${PERL5DB-unset} lib=\${PERLLIB-unset}"' \
		PERL5OPT=-Mstrict=nonsense PERL5DB=1 PERLLIB=/nonexistent
	assert_line "mode=perl"
	assert_line "opt=unset db=unset lib=unset"
	assert_line "rc=0"
}

# =============================================================================
# Resolution
# =============================================================================

@test "bounded_run_resolve: fails loudly when no bound is available" {
	local bare="${BATS_TEST_TMPDIR}/bare"
	mkdir -p "$bare"
	ln -sf "$(command -v bash)" "${bare}/bash"
	_write_runner 'bounded_run 5 1 sh -c "exit 0"'
	run env PATH="$bare" bash "$RUNNER"
	assert_failure
	assert_output --partial "Neither 'timeout' nor 'gtimeout' nor 'perl' is on PATH; no hard bound can be put on gh calls"
}

@test "bounded_run_resolve: a perl that cannot run the watchdog is no bound at all" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '#!/bin/sh\necho "Can'"'"'t locate Time/HiRes.pm" >&2\nexit 2\n' >"${mock_bin}/perl"
	chmod +x "${mock_bin}/perl"
	_write_runner 'bounded_run 5 1 touch "$STARTED_FILE"'
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash "$RUNNER"
	assert_failure
	assert_output --partial "perl cannot run the watchdog"
	[[ ! -e "$STARTED_FILE" ]] || fail "the command ran without a bound"
}

@test "bounded_run_resolve: a missing watchdog file is no bound at all" {
	# A copy of the helper without ../libexec/bounded_run_watchdog.pl, as a
	# tooling checkout that left the file out would be.
	local copy="${BATS_TEST_TMPDIR}/ci-copy/lib"
	mkdir -p "$copy"
	cp "${LIB_DIR}/bounded-run.sh" "$copy/"
	_write_runner 'bounded_run 5 1 touch "$STARTED_FILE"'
	run env PATH="$NO_TIMEOUT_PATH" LIB_DIR="$copy" bash "$RUNNER"
	assert_failure
	assert_output --partial "the perl watchdog '$(cd "${copy}/.." && pwd)/libexec/bounded_run_watchdog.pl' is missing or unreadable"
	[[ ! -e "$STARTED_FILE" ]] || fail "the command ran without a bound"
}

@test "bounded_run_resolve: an unreadable watchdog file is no bound at all" {
	((EUID != 0)) || skip "root reads any file"
	local copy="${BATS_TEST_TMPDIR}/ci-copy/lib" exec_copy="${BATS_TEST_TMPDIR}/ci-copy/libexec"
	mkdir -p "$copy" "$exec_copy"
	cp "${LIB_DIR}/bounded-run.sh" "$copy/"
	cp "${LIB_DIR}/../libexec/bounded_run_watchdog.pl" "$exec_copy/"
	chmod 000 "${exec_copy}/bounded_run_watchdog.pl"
	_write_runner 'bounded_run 5 1 touch "$STARTED_FILE"'
	run env PATH="$NO_TIMEOUT_PATH" LIB_DIR="$copy" bash "$RUNNER"
	chmod 600 "${exec_copy}/bounded_run_watchdog.pl"
	assert_failure
	assert_output --partial "is missing or unreadable"
	[[ ! -e "$STARTED_FILE" ]] || fail "the command ran without a bound"
}

@test "bounded_run: sourced by its bare name from its own directory, it finds its watchdog" {
	local runner="${BATS_TEST_TMPDIR}/bare-name.sh"
	# shellcheck disable=SC2016 # expanded by the runner
	printf '%s\n' 'set -euo pipefail' 'cd "$LIB_DIR"' 'source bounded-run.sh' \
		'bounded_run_resolve' 'rc=0' 'bounded_run 0.3 5 sleep "$MARKER" || rc=$?' \
		'echo "mode=${BOUNDED_RUN_MODE} rc=${rc}"' >"$runner"
	run env PATH="$NO_TIMEOUT_PATH" bash "$runner"
	assert_success
	assert_line "mode=perl rc=124"
	_assert_no_marked_processes
}

@test "bounded_run: the environment cannot point the helper at another watchdog" {
	# A program that would run the command with no bound at all.
	local other="${BATS_TEST_TMPDIR}/other.pl"
	# shellcheck disable=SC2016 # perl source
	printf '%s\n' 'my (undef, undef, @c) = @ARGV; exec { $c[0] } @c;' >"$other"
	SECONDS=0
	_run_fallback 'bounded_run 0.3 5 sleep "$MARKER"' _BOUNDED_RUN_WATCHDOG="$other"
	assert_line "mode=perl"
	assert_line "rc=124"
	((SECONDS < 10)) || fail "another program replaced the watchdog (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: a readonly variable naming another program cannot replace the watchdog" {
	# With the path in a global, a caller-side readonly of that name survived
	# a guarded `source` and the helper ran the other program with no bound.
	local other="${BATS_TEST_TMPDIR}/other.pl"
	printf '%s\n' 'my (undef, undef, @c) = @ARGV;' 'exec { $c[0] } @c;' >"$other"
	RUNNER="${BATS_TEST_TMPDIR}/${RUNNER_NAME}"
	printf '%s\n' 'set -uo pipefail' "trap '' PIPE" \
		"readonly _BOUNDED_RUN_WATCHDOG='${other}'" \
		'source "$LIB_DIR/bounded-run.sh" || { echo "source failed"; exit 125; }' \
		'bounded_run_resolve || exit 125' 'echo "mode=${BOUNDED_RUN_MODE}"' 'rc=0' \
		'bounded_run 0.3 5 sleep "$MARKER" || rc=$?' 'echo "rc=${rc}"' >"$RUNNER"
	SECONDS=0
	run env PATH="$NO_TIMEOUT_PATH" bash "$RUNNER"
	assert_line "mode=perl"
	assert_line "rc=124"
	((SECONDS < 10)) || fail "the other program ran without a bound (${SECONDS}s)"
	_assert_no_marked_processes
}

@test "bounded_run: an exported CDPATH does not hide the watchdog when the helper is sourced by a relative path" {
	RUNNER="${BATS_TEST_TMPDIR}/${RUNNER_NAME}"
	printf '%s\n' 'set -euo pipefail' "trap '' PIPE" 'export CDPATH=.' \
		'cd "$LIB_DIR/.."' 'source lib/bounded-run.sh' \
		'bounded_run_resolve' 'echo "mode=${BOUNDED_RUN_MODE}"' 'rc=0' \
		'bounded_run 5 1 sh -c "exit 0" || rc=$?' 'echo "rc=${rc}"' >"$RUNNER"
	run env PATH="$NO_TIMEOUT_PATH" bash "$RUNNER"
	assert_line "mode=perl"
	assert_line "rc=0"
}

@test "bounded_run: resolves the bound on first use when the caller did not" {
	# Callers may skip bounded_run_resolve; bounded_run then resolves itself,
	# and with no bound available it refuses to run the command.
	local runner="${BATS_TEST_TMPDIR}/lazy.sh" bare="${BATS_TEST_TMPDIR}/bare"
	# shellcheck disable=SC2016 # expanded by the runner
	printf '%s\n' 'set -euo pipefail' 'source "$LIB_DIR/bounded-run.sh"' 'rc=0' \
		'bounded_run 0.3 5 sleep "$MARKER" || rc=$?' \
		'echo "mode=${BOUNDED_RUN_MODE} rc=${rc}"' >"$runner"
	run env PATH="$NO_TIMEOUT_PATH" bash "$runner"
	assert_success
	assert_line "mode=perl rc=124"
	mkdir -p "$bare"
	ln -sf "$(command -v bash)" "${bare}/bash"
	ln -sf "$(command -v sleep)" "${bare}/sleep"
	run env PATH="$bare" bash "$runner"
	assert_success
	assert_line "mode= rc=125"
	assert_output --partial "no hard bound can be put on gh calls"
	_assert_no_marked_processes
}

@test "bounded_run_resolve: an explicit TIMEOUT_BIN that is not on PATH fails loudly" {
	_run_fallback 'bounded_run 5 1 sh -c "exit 0"' TIMEOUT_BIN=/nonexistent/timeout
	assert_failure
	assert_output --partial "TIMEOUT_BIN '/nonexistent/timeout' not found on PATH"
}

@test "bounded_run_resolve: prefers timeout, then gtimeout, over perl" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '#!/bin/sh\nexit 0\n' >"${mock_bin}/gtimeout"
	chmod +x "${mock_bin}/gtimeout"
	_write_runner 'echo "bin=${BOUNDED_RUN_TIMEOUT_BIN}"'
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash "$RUNNER"
	assert_line "mode=timeout"
	assert_line "bin=gtimeout"
	cp "${mock_bin}/gtimeout" "${mock_bin}/timeout"
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash "$RUNNER"
	assert_line "bin=timeout"
}

# =============================================================================
# With a timeout binary present (unchanged behaviour)
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
	_write_runner 'bounded_run 30 10 gh api -X GET "a b"'
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash "$RUNNER"
	assert_line "rc=7"
	assert_equal "$(cat "${BATS_TEST_TMPDIR}/timeout_argv")" "--kill-after=10s 30 gh api -X GET a b"
}

@test "bounded_run: a BSD-style timeout (no --version) is used as is" {
	# The BSD timeout in newer macOS /usr/bin rejects --version but takes the
	# same --kill-after form and exits 124 or 137; the stand-in does the same.
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/timeout" <<EOF
#!/bin/sh
case "\$1" in
--version) echo "timeout: unrecognized option \\\`--version'" >&2; exit 125 ;;
--kill-after=*s) ;;
*) echo "usage: timeout [-k time] duration command" >&2; exit 125 ;;
esac
printf '%s\n' "\$*" >'${BATS_TEST_TMPDIR}/timeout_argv'
exit "\${BSD_TIMEOUT_STATUS:-124}"
EOF
	chmod +x "${mock_bin}/timeout"
	_write_runner 'bounded_run 30 10 gh run view 1'
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" bash "$RUNNER"
	assert_line "mode=timeout"
	assert_line "rc=124"
	assert_equal "$(cat "${BATS_TEST_TMPDIR}/timeout_argv")" "--kill-after=10s 30 gh run view 1"
	run env PATH="${mock_bin}:${NO_TIMEOUT_PATH}" BSD_TIMEOUT_STATUS=137 bash "$RUNNER"
	assert_line "rc=137"
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
	_run_term_ignoring
	assert_line "rc=137"
	_run_fallback 'bounded_run 5 1 sh -c "exit 3"'
	assert_line "rc=3"
}

@test "bounded_run: a real BSD timeout gives the same statuses as the fallback" {
	# Newer macOS releases ship one in /usr/bin; a hosted image built on them
	# would use it rather than perl.
	[[ -x /usr/bin/timeout ]] || skip "no /usr/bin/timeout on this host"
	! /usr/bin/timeout --version 2>/dev/null | grep -q coreutils || skip "/usr/bin/timeout is GNU coreutils"
	export TIMEOUT_BIN=/usr/bin/timeout
	_run_fallback 'bounded_run 0.3 5 sleep "$MARKER"'
	assert_line "mode=timeout"
	assert_line "rc=124"
	_run_term_ignoring
	assert_line "rc=137"
	_run_fallback 'bounded_run 5 1 sh -c "exit 3"'
	assert_line "rc=3"
	_assert_no_marked_processes
}
