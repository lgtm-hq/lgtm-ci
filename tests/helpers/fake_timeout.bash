#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Deterministic test doubles of coreutils timeout for BATS tests.
#
# Usage: In your .bats file:
#   load "../../helpers/fake_timeout"
#   install_fake_timeout "$dir/gnutimeout" gnu
#
# Modes (the command is always run in a process group of its own, and
# DURATION and --kill-after=N are whole seconds):
#   gnu           banner "timeout (GNU coreutils) ..."; on expiry SIGTERM to the
#                 group, then after --kill-after SIGKILL to the group (GNU's
#                 behaviour).
#   uutils        banner "timeout (uutils coreutils) ..."; SIGTERM to the
#                 group, but the later SIGKILL to the direct child only, as
#                 uutils 0.8.0 on ubuntu-26.04 does (#1656).
#   gnu-hang      a gnu double whose --version never answers (it writes its
#                 pid to $FAKE_TIMEOUT_PROBE_PID_FILE when that is set).
# Exit status: the command's, 124 after a timeout, or 137 after SIGKILL.

install_fake_timeout() {
	local path="${1:?path required}" mode="${2:?mode required}" banner="GNU" kill_group=1 hang=0
	case "$mode" in
	gnu) ;;
	uutils)
		banner="uutils"
		kill_group=0
		;;
	gnu-hang) hang=1 ;;
	*)
		echo "install_fake_timeout: unknown mode '$mode'" >&2
		return 1
		;;
	esac
	{
		printf '#!/usr/bin/env perl\n'
		# shellcheck disable=SC2016 # Perl variables, written literally into the script.
		printf 'my ($BANNER, $KILL_GROUP, $HANG) = ("%s", %d, %d);\n' "$banner" "$kill_group" "$hang"
		cat <<'PERL'
use strict;
use warnings;
if (@ARGV && $ARGV[0] eq '--version') {
	if ($HANG) {
		# The pid stays the same through exec, so a test can check the probe was killed.
		if (my $file = $ENV{FAKE_TIMEOUT_PROBE_PID_FILE}) { open(my $fh, '>', $file) or die "$file: $!"; print $fh "$$\n"; close $fh }
		exec 'sleep', '300' or die "sleep: $!";
	}
	print "timeout ($BANNER coreutils) 0.0.0-test\n";
	exit 0;
}
my ($kill_after) = (shift(@ARGV) // '') =~ /^--kill-after=(\d+)$/ or die "fake timeout: --kill-after=N first\n";
my $duration = shift(@ARGV);
die "fake timeout: whole-second DURATION expected\n" unless defined $duration && $duration =~ /^\d+$/;
my $pid = fork() // die "fork: $!";
if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!" }
setpgrp($pid, $pid);
sub wait_for { my ($seconds) = @_; my $status;
	eval { local $SIG{ALRM} = sub { die "alarm\n" }; alarm $seconds; waitpid($pid, 0); $status = $?; alarm 0; };
	return $status; }
my $status = wait_for($duration);
exit($status & 127 ? 128 + ($status & 127) : $status >> 8) if defined $status;
kill 'TERM', -$pid;
exit 124 if defined wait_for($kill_after);
kill 'KILL', ($KILL_GROUP ? -$pid : $pid);
waitpid($pid, 0);
exit 137;
PERL
	} >"$path"
	chmod +x "$path"
}
