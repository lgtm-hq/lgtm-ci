# SPDX-License-Identifier: MIT
# Purpose: The perl watchdog of bounded-run.sh (#1729): run a command under a
#          hard wall-clock bound where no `timeout` binary is on PATH.
#
# Not an entrypoint: bounded-run.sh runs it, from its own directory, as
#   env -u PERL... perl bounded_run_watchdog.pl <seconds> <grace> <command...>
# after checking the arguments (decimal numbers of at least 0.001) and that
# perl can compile this file. The contract (process group, TERM then KILL,
# statuses 124/137/125/126/127, cleanup of the group) is documented in
# bounded-run.sh's header; its tests are tests/bats/unit/lib/test_bounded_run.bats.
#
# Environment: BOUNDED_RUN_FAULT (test hook, see bounded-run.sh) makes the
# named step fail so the tests can prove it fails closed.

use strict;
use warnings;
use POSIX ();
use Time::HiRes qw(setitimer ITIMER_REAL);

my ($seconds, $grace, @command) = @ARGV;
my $fault = $ENV{BOUNDED_RUN_FAULT} // "";
# The largest interval timer macOS accepts; a larger value is capped, so it
# is still a bound.
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
# only recorded, never sent (a group of 0 would be the caller's own).
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
# harmlessly once the child has exec'd (the child's own call decides).
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
# Whatever the command left in its group must not keep the caller's output
# open after it.
kill("KILL", -$pid);
exit 125 if $timer_failed;
if ($timed_out) {
	exit((($status & 127) == 9) ? 137 : 124);
}
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
