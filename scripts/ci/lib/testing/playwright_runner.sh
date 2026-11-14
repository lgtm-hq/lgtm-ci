#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail early when @playwright/test is too old for the runner image (#1313)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/playwright_runner.sh"
#   check_playwright_runner_support "$version"
#
# Optional environment variables:
#   OS_RELEASE_FILE - os-release file to read (default: /etc/os-release); lets
#                     tests avoid reading the host file

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_PLAYWRIGHT_RUNNER_LOADED:-}" ]] && return 0
readonly _LGTM_CI_PLAYWRIGHT_RUNNER_LOADED=1

_PLAYWRIGHT_RUNNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
if ! declare -F log_info >/dev/null 2>&1; then
	# shellcheck source=../log.sh
	source "$_PLAYWRIGHT_RUNNER_LIB_DIR/../log.sh"
fi

# Single source of truth for the minimum @playwright/test (major.minor) whose
# browser builds support Ubuntu 26.04. Upstream: "Playwright now supports
# Ubuntu 26.04" in the v1.61.0 release notes,
# https://github.com/microsoft/playwright/releases/tag/v1.61.0 (v1.60.0 notes
# carry no such entry).
PLAYWRIGHT_MIN_VERSION_UBUNTU_2604="1.61"

# Print the VERSION_ID of the running OS (empty when unreadable).
playwright_runner_os_version_id() {
	local file="${OS_RELEASE_FILE:-/etc/os-release}"
	local id="" version_id=""
	[[ -r "$file" ]] || return 0
	while IFS='=' read -r key value; do
		value="${value%\"}"
		value="${value#\"}"
		case "$key" in
		ID) id="$value" ;;
		VERSION_ID) version_id="$value" ;;
		esac
	done <"$file"
	[[ "$id" == "ubuntu" ]] && printf '%s' "$version_id"
	return 0
}

# Return 0 when version $1 (e.g. 1.55.0) is below minimum $2 (major.minor).
# Return 2 when $1 is not parseable as major.minor.
playwright_version_below() {
	local version="$1" minimum="$2"
	local major minor min_major min_minor
	if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
		return 2
	fi
	major="${BASH_REMATCH[1]}"
	minor="${BASH_REMATCH[2]}"
	min_major="${minimum%%.*}"
	min_minor="${minimum#*.}"
	((10#$major < 10#$min_major || (10#$major == 10#$min_major && 10#$minor < 10#$min_minor)))
}

# Return 0 when the running OS is Ubuntu 26.04 (detected from os-release, not
# from the runs-on label).
playwright_runner_is_ubuntu_2604() {
	[[ "$(playwright_runner_os_version_id)" == "26.04" ]]
}

# Fail (return 1) with an ::error:: when the runner is Ubuntu 26.04 and the
# resolved @playwright/test version is below the minimum. An unresolvable
# version warns and continues.
# Usage: check_playwright_runner_support <version>
check_playwright_runner_support() {
	local version="${1:-unknown}"
	local minimum="$PLAYWRIGHT_MIN_VERSION_UBUNTU_2604"

	playwright_runner_is_ubuntu_2604 || return 0

	local rc=0
	playwright_version_below "$version" "$minimum" || rc=$?
	case "$rc" in
	0)
		echo "::error::@playwright/test ${version} has no browser builds for Ubuntu 26.04; ${minimum} or newer is required. Bump @playwright/test to ${minimum}+ (runner-image: ubuntu-24.04 is a temporary escape hatch only)."
		return 1
		;;
	2)
		echo "::warning::Could not resolve the @playwright/test version (got '${version}'); skipping the Ubuntu 26.04 minimum check (requires ${minimum}+)."
		;;
	esac
	return 0
}

# Return 0 on a Linux runner (RUNNER_OS, else uname), the only OS where
# Playwright's browsers need system packages from apt.
playwright_runner_is_linux() {
	[[ "${RUNNER_OS:-$(uname -s)}" == "Linux" ]]
}

# Seconds one browser download attempt may run (#1563). A hung download
# (fixture run 43557274435 sat 25 minutes in `Install Playwright browsers`)
# then fails fast instead of eating the job budget. Override per call with
# PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS.
PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT=300
# Seconds between TERM and KILL when an attempt outlives its deadline.
# Override with PLAYWRIGHT_INSTALL_KILL_GRACE_SECONDS.
PLAYWRIGHT_INSTALL_KILL_GRACE_DEFAULT=10

# Print the coreutils timeout binary (`timeout`, or `gtimeout` where coreutils
# is installed under that name); return 1 when neither is a coreutils timeout.
# The hosted macOS images ship neither, and Windows ships an unrelated
# `timeout.exe`; playwright_bounded_run then uses its own watchdog.
playwright_timeout_bin() {
	local candidate
	for candidate in timeout gtimeout; do
		if command -v "$candidate" >/dev/null 2>&1 &&
			"$candidate" --version 2>/dev/null | grep -q coreutils; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}

# Return 0 when perl is on PATH (every GitHub-hosted image ships it); the
# fallback watchdog uses it to start an attempt in its own process group,
# else it turns on bash job control (`set -m`) for that one job.
playwright_have_perl() {
	command -v perl >/dev/null 2>&1
}

# Print the current time in microseconds (EPOCHREALTIME on bash 5, else perl,
# else whole seconds from date).
_playwright_now_us() {
	if [[ -n "${EPOCHREALTIME:-}" ]]; then
		printf '%s' "${EPOCHREALTIME//[!0-9]/}"
	elif playwright_have_perl; then
		perl -MTime::HiRes=time -e 'printf "%d", time() * 1e6'
	else
		printf '%s' "$(($(date +%s) * 1000000))"
	fi
}

# Send signal $1 to the process group led by $2, or to $2 alone when it leads
# no group (the attempt has not called setpgrp yet).
_playwright_signal() {
	kill "-$1" -- "-$2" 2>/dev/null || kill "-$1" "$2" 2>/dev/null || true
}

# Run one command bounded by a deadline, reporting whether the deadline fired.
#
# With a coreutils timeout (playwright_timeout_bin) the command runs under
# `timeout --kill-after=<grace> <seconds>`; the deadline fired when the exit
# code is 124 or 137 and at least <seconds> really elapsed, so a command that
# exits 124 by itself or is killed early (OOM) does not count. Otherwise a
# watchdog in bash runs the command in the background in its own process
# group (perl `setpgrp` then `exec`, else bash job control); after <seconds> it
# sends TERM to the group, then KILL after <grace> if anything still runs;
# when it fired, any process left in the group is killed once the command
# ends, so a hung grandchild does not outlive the attempt. The exit code then
# mirrors coreutils: 124 after TERM, 137 after KILL. In the background the
# command's stdin is /dev/null.
#
# Prints nothing. Writes "1" to <fired_file> when the deadline fired, else
# leaves it empty. Returns the command's exit code.
#
# Usage: playwright_bounded_run <seconds> <grace> <fired_file> <command...>
playwright_bounded_run() {
	local seconds="$1" grace="$2" fired_file="$3" timeout_bin="" rc=0
	local start=0 elapsed=0 pid=0 watchdog=0 signal="" monitor=1
	shift 3
	: >"$fired_file"
	if timeout_bin="$(playwright_timeout_bin)"; then
		start="$(_playwright_now_us)"
		"$timeout_bin" --kill-after="$grace" "$seconds" "$@" || rc=$?
		elapsed=$(($(_playwright_now_us) - start))
		if { ((rc == 124)) || ((rc == 137)); } && ((elapsed >= seconds * 1000000)); then
			echo 1 >"$fired_file"
		fi
		return "$rc"
	fi

	if playwright_have_perl; then
		perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or do {
			print STDERR "$ARGV[0]: $!\n"; exit 127 }' -- "$@" </dev/null &
		pid=$!
	else
		# Job control gives the background job its own process group.
		[[ $- == *m* ]] || monitor=0
		set -m
		"$@" </dev/null &
		pid=$!
		((monitor)) || set +m
	fi
	# The watchdog records which signal it sent in <fired_file> before
	# sending it; its own sleeps are killed with it, and its stdio is closed
	# so no sleeper holds the caller's output open.
	(
		sleeper=0
		trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
		sleep "$seconds" &
		sleeper=$!
		wait "$sleeper"
		kill -0 "$pid" 2>/dev/null || exit 0
		echo TERM >"$fired_file"
		_playwright_signal TERM "$pid"
		sleep "$grace" &
		sleeper=$!
		wait "$sleeper"
		kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || exit 0
		echo KILL >"$fired_file"
		_playwright_signal KILL "$pid"
	) </dev/null >/dev/null 2>&1 &
	watchdog=$!
	wait "$pid" || rc=$?
	signal="$(cat "$fired_file" 2>/dev/null || true)"
	if [[ -n "$signal" ]]; then
		# Past the deadline: nothing left in the attempt's group may live on.
		_playwright_signal KILL "$pid"
	fi
	kill -TERM "$watchdog" 2>/dev/null || true
	wait "$watchdog" 2>/dev/null || true
	# The watchdog may have escalated to KILL after the attempt ended.
	signal="$(cat "$fired_file" 2>/dev/null || true)"
	case "$signal" in
	TERM) rc=124 ;;
	KILL) rc=137 ;;
	*) return "$rc" ;;
	esac
	echo 1 >"$fired_file"
	return "$rc"
}

# Run one Playwright browser download command, bounded and retried once
# (#1563). Each attempt runs through playwright_bounded_run: coreutils
# timeout where present (the Ubuntu images), otherwise the bash watchdog
# (the hosted macOS images ship no coreutils timeout), either way TERM after
# PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS and KILL after
# PLAYWRIGHT_INSTALL_KILL_GRACE_SECONDS more. A failed or timed-out first
# attempt prints a ::warning:: and runs again.
#
# When both attempts fail, exactly one ::error:: is printed:
#   - both hit the deadline: "Playwright browser install timed out twice
#     (<N>s per attempt)", the external canary's playwright-download
#     infrastructure signature (scripts/ci/lib/infra-signatures.sh; keep
#     them in sync);
#   - otherwise: "Playwright browser install failed twice (timeout or
#     error)", which the canary never retries: an error exit may be a
#     product regression (a bad browser name, an unsupported version).
# Returns the last attempt's exit code.
#
# Usage: playwright_install_with_retry <command...>
playwright_install_with_retry() {
	[[ $# -gt 0 ]] || {
		log_error "playwright_install_with_retry: command required"
		return 2
	}
	local seconds="${PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS:-$PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT}"
	local grace="${PLAYWRIGHT_INSTALL_KILL_GRACE_SECONDS:-$PLAYWRIGHT_INSTALL_KILL_GRACE_DEFAULT}"
	if [[ ! "$seconds" =~ ^[1-9][0-9]*$ ]]; then
		log_error "PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS must be a positive integer (got '${seconds}')"
		return 2
	fi
	if [[ ! "$grace" =~ ^[1-9][0-9]*$ ]]; then
		log_error "PLAYWRIGHT_INSTALL_KILL_GRACE_SECONDS must be a positive integer (got '${grace}')"
		return 2
	fi
	local attempt rc=0 timeouts=0 fired_file
	fired_file="$(mktemp "${TMPDIR:-/tmp}/playwright-install.XXXXXX")" || return 2
	for attempt in 1 2; do
		rc=0
		playwright_bounded_run "$seconds" "$grace" "$fired_file" "$@" || rc=$?
		if ((rc == 0)); then
			rm -f "$fired_file"
			return 0
		fi
		if [[ "$(cat "$fired_file")" == 1 ]]; then
			timeouts=$((timeouts + 1))
			((attempt == 2)) || echo "::warning title=Playwright browser install::attempt 1" \
				"timed out after ${seconds}s; retrying once"
		elif ((attempt == 1)); then
			echo "::warning title=Playwright browser install::attempt 1 failed (exit ${rc});" \
				"retrying once"
		fi
	done
	rm -f "$fired_file"
	if ((timeouts == 2)); then
		echo "::error::Playwright browser install timed out twice (${seconds}s per attempt)"
	else
		echo "::error::Playwright browser install failed twice (timeout or error)"
	fi
	return "$rc"
}

# Install Playwright browsers (#1432).
#
# On Linux the system packages are installed by the shared apt helper, never
# by Playwright: `apt_helper.py update` refreshes the package lists,
# `playwright install-deps --dry-run` reports the packages (parsed by
# playwright_deps.py), `apt_helper.py install --no-update
# --no-install-recommends` installs them (as Playwright itself would, without
# refreshing the lists a second time), and
# `playwright install` downloads the browsers without --with-deps. When the
# dry run's output is not recognised, a ::warning:: is printed and the
# original `playwright install --with-deps` runs instead, which is what ran
# before. Off Linux (macOS, Windows) `install --with-deps` runs unchanged: it
# never calls apt there. Every browser download (`install`, with or without
# --with-deps) runs through playwright_install_with_retry (#1563); the apt
# helper keeps its own bounded retries. In the `--with-deps` fallback the apt
# run shares the download's deadline: a TERM in the middle of dpkg makes the
# second attempt fail with the generic error, which the canary never retries.
#
# Usage: playwright_install_browsers <browsers|all> <launcher...>
#   browsers - space-separated browser names, or "all" (no names)
#   launcher - the command that runs the Playwright CLI, e.g. npx playwright
playwright_install_browsers() {
	local browsers="${1:?playwright_install_browsers: browsers required}"
	shift
	[[ $# -gt 0 ]] || {
		log_error "playwright_install_browsers: launcher required"
		return 2
	}
	local -a names=() packages=()
	if [[ "$browsers" != "all" ]]; then
		read -ra names <<<"$browsers"
	fi
	if ! playwright_runner_is_linux; then
		playwright_install_with_retry "$@" install --with-deps "${names[@]+"${names[@]}"}"
		return
	fi

	local lib="$_PLAYWRIGHT_RUNNER_LIB_DIR/.." dry_run="" dry_rc=0 parsed=""
	python3 -I "$lib/apt_helper.py" update || return $?
	dry_run="$("$@" install-deps --dry-run "${names[@]+"${names[@]}"}" 2>&1)" || dry_rc=$?
	if ! parsed="$(printf '%s\n' "$dry_run" |
		python3 -I "$lib/playwright_deps.py" --exit-code "$dry_rc")"; then
		echo "::warning title=Playwright system packages::playwright install-deps --dry-run output was not recognised; falling back to playwright install --with-deps, which runs apt without the shared helper's timeouts and retries"
		playwright_install_with_retry "$@" install --with-deps "${names[@]+"${names[@]}"}"
		return
	fi
	read -ra packages <<<"$(printf '%s' "$parsed" | tr '\n' ' ')"
	if [[ ${#packages[@]} -gt 0 ]]; then
		log_info "Installing ${#packages[@]} Playwright system packages through the apt helper..."
		# The lists were refreshed by the helper's update above.
		python3 -I "$lib/apt_helper.py" install --no-update --no-install-recommends \
			"${packages[@]}" || return $?
	else
		log_info "Playwright reports every system package installed"
	fi
	playwright_install_with_retry "$@" install "${names[@]+"${names[@]}"}"
}
