#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a command under a hard wall-clock bound: a `timeout` binary
#          where the runner has one, a perl watchdog where it does not (#1729).
#
# `runner-image` is a caller input, so a script that bounds its `gh` calls
# can land on a hosted macOS image, which ships neither `timeout` nor
# `gtimeout` but does ship perl (as every hosted Ubuntu image does).
#
# Which bound (bounded_run_resolve): TIMEOUT_BIN when set, else the first
# `timeout`, then `gtimeout`, on PATH. Any binary of that name is accepted:
# GNU coreutils and the BSD `timeout` that newer macOS releases ship in
# /usr/bin both take `--kill-after=<grace>s <seconds>` and exit 124 after
# SIGTERM and 137 after SIGKILL. With neither, the perl watchdog below; with
# no perl able to load POSIX and Time::HiRes either, no bound is available
# and the caller must not run the command.
#
# The perl watchdog keeps the `timeout --kill-after` contract the callers
# rely on:
#
#   - the command runs in its own process group (or not at all: status 125)
#     with the caller's stdio and SIGPIPE disposition, and is exec'd, not
#     wrapped in a shell;
#   - after <seconds> the group gets SIGTERM, and SIGKILL <grace> seconds
#     later if the command is still running; a TERM, INT or HUP sent to the
#     watchdog is passed to the group and starts the same SIGKILL grace;
#   - the status is the command's own when the bound did not fire (128+N
#     when signal N ended it), 124 when it fired and the command ended after
#     SIGTERM, 137 when SIGKILL was needed; 125 when the bound could not be
#     set up (no process group, a timer that could not be armed: the group
#     is then killed), 126/127 when the command could not be run;
#   - when the command exits, whatever is left in its process group is
#     killed, so a background child cannot hold the caller's `$(...)` open.
#     Coreutils `timeout` leaves such children running; the fallback is
#     stricter on purpose;
#   - no timer or watchdog process outlives the call (the timer is perl's
#     own interval timer in the same process).
#
# The watchdog's perl runs with every PERL* variable removed (PERL5OPT,
# PERL5LIB, PERLLIB, PERL5DB, PERL_UNICODE, PERL_SIGNALS and the rest), so
# no PERL* variable can preload code into it or replace its timer.
# The command inherits that cleaned environment: `gh`, the command callers
# bound today, reads none of these variables.
#
# <seconds> and <grace> are decimal numbers of at least 0.001 (finer values
# are refused with status 125, before anything runs, in both modes). The
# perl watchdog caps either at 100000000 (about 3.2 years, the largest
# interval timer macOS accepts), so a larger value is still a bound; a
# `timeout` binary receives the value unchanged, as before.
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
#   TIMEOUT_BIN        (optional) `timeout` binary. When set it must be on
#                      PATH; when unset, `timeout`, then `gtimeout`, then the
#                      perl watchdog is used.
#   BOUNDED_RUN_FAULT  Test hook: "setpgrp", "bound" or "grace" makes that
#                      step of the perl watchdog fail, to prove it fails
#                      closed (status 125). It can only stop a command, never
#                      lift a bound.
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
my $fault = $ENV{BOUNDED_RUN_FAULT} // "";
my $longest = 100000000;
$seconds = $longest if $seconds > $longest;
$grace = $longest if $grace > $longest;
my ($pid, $timed_out, $grace_armed, $timer_failed, $pending) = (0, 0, 0, 0, "");
sub signal_group {
	my ($name) = @_;
	kill($name, -$pid) or kill($name, $pid);
}
# Arm the interval timer; on failure kill the group, so a bound that cannot
# be kept never lets the command run on.
sub arm {
	my ($value, $what) = @_;
	my @previous = $fault eq $what ? () : setitimer(ITIMER_REAL, $value);
	return 1 if @previous;
	print STDERR "bounded_run: could not arm the ${what} timer; killing the command\n";
	$timer_failed = 1;
	signal_group("KILL");
	return 0;
}
sub start_grace {
	return if $grace_armed;
	$grace_armed = 1;
	arm($grace, "grace");
}
# Installed before fork, so a cancel cannot slip between the command
# starting and its watchdog listening. Before the command exists a signal is
# only recorded, never sent (a group of 0 would be the caller'\''s own).
$SIG{ALRM} = sub {
	return unless $pid;
	if ($grace_armed) {
		signal_group("KILL");
		return;
	}
	$timed_out = 1;
	signal_group("TERM");
	start_grace();
};
for my $name (qw(HUP INT TERM)) {
	$SIG{$name} = sub {
		if (!$pid) {
			$pending ||= $name;
			return;
		}
		signal_group($name);
		start_grace();
	};
}
$pid = fork();
if (!defined $pid) {
	print STDERR "bounded_run: fork failed: $!\n";
	exit 125;
}
if ($pid == 0) {
	$SIG{$_} = "DEFAULT" for qw(ALRM HUP INT TERM);
	if ($fault eq "setpgrp" || !setpgrp(0, 0)) {
		print STDERR "bounded_run: no process group of its own for $command[0]; not running it\n";
		POSIX::_exit(125);
	}
	{ no warnings "exec"; exec { $command[0] } @command; }
	my $status = $!{ENOENT} ? 127 : 126;
	print STDERR "bounded_run: $command[0]: $!\n";
	POSIX::_exit($status);
}
# Also from this side, so the group exists before any signal is sent; fails
# harmlessly once the child has exec'\''d (the child'\''s own call decides).
setpgrp($pid, $pid);
if ($pending) {
	signal_group($pending);
	start_grace();
} else {
	arm($seconds, "bound");
}
my $reaped;
do { $reaped = waitpid($pid, 0) } until $reaped == $pid || !$!{EINTR};
my $status = $?;
setitimer(ITIMER_REAL, 0);
# Whatever the command left in its group must not keep the caller'\''s output
# open after it.
kill("KILL", -$pid);
exit 125 if $timer_failed;
if ($timed_out) {
	exit((($status & 127) == 9) ? 137 : 124);
}
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
'

# Run perl with every PERL* variable removed from its environment. Fails
# (status 125) when the variables cannot be listed, rather than run perl
# with them. The variables are removed by `env -u`, not by `unset`: a
# variable the sourcing shell made readonly cannot be unset, and an
# unchecked failure there would start perl with it.
_bounded_run_perl() {
	(
		names="$(compgen -e)" || exit 125
		# The caller's IFS must not stop the names from splitting.
		IFS=$' \t\n'
		launch=(env)
		for name in $names; do
			case "$name" in
			PERL*) launch+=(-u "$name") ;;
			esac
		done
		exec "${launch[@]}" perl "$@"
	)
}

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
	if ! command -v perl >/dev/null 2>&1; then
		echo "::error::Neither 'timeout' nor 'gtimeout' nor 'perl' is on PATH; no hard bound can be put on gh calls (install coreutils or perl, or set TIMEOUT_BIN)"
		return 1
	fi
	if ! _bounded_run_perl -MPOSIX -MTime::HiRes=setitimer,ITIMER_REAL -e 1 >/dev/null 2>&1; then
		echo "::error::Neither 'timeout' nor 'gtimeout' is on PATH, and perl cannot run the watchdog (it must load POSIX and Time::HiRes with every PERL* variable removed); no hard bound can be put on gh calls (install coreutils, or set TIMEOUT_BIN)"
		return 1
	fi
	BOUNDED_RUN_MODE=perl
	return 0
}

# True when $1 is a decimal number of at least 0.001.
_bounded_run_duration() {
	local value="$1" whole fraction
	[[ "$value" =~ ^([0-9]+[.]?[0-9]*|[.][0-9]+)$ ]] || return 1
	whole="${value%%.*}"
	fraction=""
	[[ "$value" == *.* ]] && fraction="${value#*.}000"
	[[ "$whole" =~ [1-9] || "${fraction:0:3}" =~ [1-9] ]]
}

# Run a command bounded by <seconds>, then SIGKILL after <grace> more
# seconds (see the file header for the range and the statuses). Returns the
# command's status, or 124/137 when the bound fired.
#
# Usage: bounded_run <seconds> <grace> <command...>
bounded_run() {
	local seconds="${1:-}" grace="${2:-}"
	if [[ $# -lt 3 ]]; then
		echo "bounded_run: usage: bounded_run <seconds> <grace> <command...>" >&2
		return 125
	fi
	shift 2
	if ! _bounded_run_duration "$seconds" || ! _bounded_run_duration "$grace"; then
		echo "bounded_run: <seconds> and <grace> must be decimal numbers of at least 0.001 (got '${seconds}' and '${grace}')" >&2
		return 125
	fi
	if [[ -z "$BOUNDED_RUN_MODE" ]]; then
		bounded_run_resolve >&2 || return 125
	fi
	if [[ "$BOUNDED_RUN_MODE" == timeout ]]; then
		"$BOUNDED_RUN_TIMEOUT_BIN" --kill-after="${grace}s" "$seconds" "$@"
	else
		_bounded_run_perl -e "$_BOUNDED_RUN_PERL" -- "$seconds" "$grace" "$@"
	fi
}
