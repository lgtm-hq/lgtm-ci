#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a command under a hard wall-clock bound: coreutils `timeout`
#          where the runner has it, a perl watchdog where it does not (#1729).
#
# `runner-image` is a caller input, so a script that bounds its `gh` calls
# can land on a hosted macOS image, which ships neither `timeout` nor
# `gtimeout` but does ship perl (as every hosted Ubuntu image does). The
# perl watchdog keeps the coreutils contract the callers rely on:
#
#   - the command runs in its own process group with the caller's stdio
#     (SIGPIPE disposition included) and is exec'd, not wrapped in a shell;
#   - after <seconds> the group gets SIGTERM, and SIGKILL <grace> seconds
#     later if the command is still running;
#   - the status is the command's own when the bound did not fire, 124 when
#     it fired and the command ended after SIGTERM, 137 when SIGKILL was
#     needed (coreutils `timeout --kill-after`); 125 when the bound could not
#     be started, 126/127 when the command could not be run;
#   - once the bound fired, nothing left in the command's process group
#     outlives the call; a command that ends early returns at once, and no
#     timer or watchdog process is left behind (the timer is perl's own
#     interval timer in the same process).
#
# One perl process, rather than a background watchdog in bash, because a
# bash watchdog needs an external `sleep` (which callers' tests stub), job
# control for the process group, and a second process that must not hold
# the caller's output pipe open; all of these differ between bash 3.2 (the
# hosted macOS `bash`) and bash 5.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/bounded-run.sh"
#   bounded_run_resolve || exit 1
#   bounded_run 30 10 gh api ... </dev/null
#
# Environment:
#   TIMEOUT_BIN  (optional) coreutils timeout binary. When set it must be on
#                PATH; when unset, `timeout`, then `gtimeout`, then the perl
#                watchdog is used.
#
# This is a sourced library, not an entrypoint.

[[ -n "${_LGTM_CI_BOUNDED_RUN_LOADED:-}" ]] && return 0
readonly _LGTM_CI_BOUNDED_RUN_LOADED=1

# "timeout" (BOUNDED_RUN_TIMEOUT_BIN names the binary) or "perl"; set by
# bounded_run_resolve.
BOUNDED_RUN_MODE=""
BOUNDED_RUN_TIMEOUT_BIN=""

# Arguments: seconds, grace, command... (after perl's own `--`).
# shellcheck disable=SC2016 # perl source: its `$` must reach perl unexpanded
_BOUNDED_RUN_PERL='
use strict;
use warnings;
use POSIX ();
use Time::HiRes qw(setitimer ITIMER_REAL);
my ($seconds, $grace, @command) = @ARGV;
my $pid = fork();
if (!defined $pid) {
	print STDERR "bounded_run: fork failed: $!\n";
	exit 125;
}
if ($pid == 0) {
	setpgrp(0, 0);
	{ no warnings "exec"; exec { $command[0] } @command; }
	my $status = $!{ENOENT} ? 127 : 126;
	print STDERR "bounded_run: $command[0]: $!\n";
	POSIX::_exit($status);
}
# Also from this side, so the group exists before the timer can fire; fails
# harmlessly once the child has exec'\''d.
setpgrp($pid, $pid);
my $stage = 0;
my $signal = sub {
	my ($name) = @_;
	kill($name, -$pid) or kill($name, $pid);
};
$SIG{ALRM} = sub {
	if ($stage == 0) {
		$stage = 1;
		$signal->("TERM");
		setitimer(ITIMER_REAL, $grace);
	} else {
		$stage = 2;
		$signal->("KILL");
	}
};
# A cancelled step signals this process; pass it on, like coreutils does.
for my $name (qw(HUP INT TERM)) {
	$SIG{$name} = sub { $signal->($name) };
}
setitimer(ITIMER_REAL, $seconds);
my $reaped;
do { $reaped = waitpid($pid, 0) } until $reaped == $pid || !$!{EINTR};
my $status = $?;
setitimer(ITIMER_REAL, 0);
if ($stage > 0) {
	kill("KILL", -$pid);
	exit((($status & 127) == 9) ? 137 : 124);
}
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
'

# Pick how bounded_run bounds a command. Prints an ::error:: line and returns
# 1 when no bound is available, so a caller never runs a command unbounded.
bounded_run_resolve() {
	local candidate
	BOUNDED_RUN_MODE=""
	BOUNDED_RUN_TIMEOUT_BIN=""
	if [[ -n "${TIMEOUT_BIN:-}" ]]; then
		if ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
			echo "::error::TIMEOUT_BIN '${TIMEOUT_BIN}' not found on PATH; coreutils timeout is required to bound gh calls"
			return 1
		fi
		BOUNDED_RUN_MODE=timeout
		BOUNDED_RUN_TIMEOUT_BIN="$TIMEOUT_BIN"
		return 0
	fi
	for candidate in timeout gtimeout; do
		if command -v "$candidate" >/dev/null 2>&1; then
			BOUNDED_RUN_MODE=timeout
			BOUNDED_RUN_TIMEOUT_BIN="$candidate"
			return 0
		fi
	done
	if command -v perl >/dev/null 2>&1; then
		BOUNDED_RUN_MODE=perl
		return 0
	fi
	echo "::error::Neither 'timeout' nor 'gtimeout' nor 'perl' is on PATH; no hard bound can be put on gh calls (install coreutils or perl, or set TIMEOUT_BIN)"
	return 1
}

# Run a command bounded by <seconds>, then SIGKILL after <grace> more
# seconds; both are positive numbers and may be fractional. Returns the
# command's status, or 124/137 when the bound fired (see the file header).
#
# Usage: bounded_run <seconds> <grace> <command...>
bounded_run() {
	local seconds="${1:-}" grace="${2:-}"
	local number='^([0-9]+[.]?[0-9]*|[.][0-9]+)$'
	if [[ $# -lt 3 ]]; then
		echo "bounded_run: usage: bounded_run <seconds> <grace> <command...>" >&2
		return 125
	fi
	shift 2
	if [[ ! "$seconds" =~ $number || ! "$seconds" =~ [1-9] ]] ||
		[[ ! "$grace" =~ $number || ! "$grace" =~ [1-9] ]]; then
		echo "bounded_run: <seconds> and <grace> must be positive numbers (got '${seconds}' and '${grace}')" >&2
		return 125
	fi
	if [[ -z "$BOUNDED_RUN_MODE" ]]; then
		bounded_run_resolve >&2 || return 125
	fi
	if [[ "$BOUNDED_RUN_MODE" == timeout ]]; then
		"$BOUNDED_RUN_TIMEOUT_BIN" --kill-after="${grace}s" "$seconds" "$@"
	else
		perl -e "$_BOUNDED_RUN_PERL" -- "$seconds" "$grace" "$@"
	fi
}
