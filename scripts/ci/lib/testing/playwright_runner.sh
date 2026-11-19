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
# Wall-clock budget, in seconds, of each apt helper run on the Linux path
# (#1571): `update` and `install --no-update` each end, with the helper's own
# annotation, within it (LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS; a caller's value
# wins), cut to what is left of the install budget below (#1433).
PLAYWRIGHT_APT_TIMEOUT_DEFAULT=300
# Seconds one `playwright install-deps --dry-run` or `install --dry-run` may
# run (#1433). Both only read local data (the package database, the browser
# registry); KILL follows after the kill grace.
PLAYWRIGHT_DRY_RUN_TIMEOUT_DEFAULT=30
# Seconds the single `playwright install-deps` attempt may run when it
# replaces `install --with-deps` because the browsers are already on disk
# (#1433): it installs the system packages without downloading again.
PLAYWRIGHT_INSTALL_DEPS_TIMEOUT_DEFAULT=300
# Wall-clock budget, in seconds, of one playwright_install_browsers call
# (#1433), shared by every stage: browser downloads, apt helper runs, both dry
# runs, the ldd probe and the install-deps fallback. Each stage is cut to what
# is left of it, and a stage with less than PLAYWRIGHT_STAGE_MIN_SECONDS left
# fails with one ::error:: instead of starting. 1380s leaves 120s of the
# 25-minute (1500s) `Install Playwright browsers` step of
# reusable-test-e2e-playwright.yml for start-up and the version checks;
# tests/python/test_playwright_install_bound.py pins the worst case of every
# path against both. Override with PLAYWRIGHT_INSTALL_BUDGET_SECONDS.
PLAYWRIGHT_INSTALL_BUDGET_DEFAULT=1380
# The shortest time a bounded stage is started with (the apt helper's own
# minimum budget is 30s).
PLAYWRIGHT_STAGE_MIN_SECONDS=30

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
		# coreutils timeout makes itself the leader of a new process group.
		# When its direct child exits on TERM it returns at once and never
		# sends KILL, so a TERM-ignoring grandchild would outlive the attempt:
		# kill the group explicitly once the deadline has fired.
		"$timeout_bin" --kill-after="$grace" "$seconds" "$@" </dev/null &
		pid=$!
		wait "$pid" || rc=$?
		elapsed=$(($(_playwright_now_us) - start))
		if { ((rc == 124)) || ((rc == 137)); } && ((elapsed >= seconds * 1000000)); then
			echo 1 >"$fired_file"
			_playwright_signal KILL "$pid"
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

# Print the trimmed value of option variable $1 (default $2); fail with an
# ::error:: when it is not one of the remaining arguments.
# Usage: playwright_install_option <variable> <default> <allowed...>
playwright_install_option() {
	local name="$1" default="$2" value allowed
	shift 2
	value="${!name:-}"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	value="${value:-$default}"
	for allowed in "$@"; do
		if [[ "$value" == "$allowed" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done
	echo "::error title=Playwright install::${name} must be one of: $* (got '${value}')" >&2
	return 2
}

# Print the first Python 3.10+ interpreter on PATH: python3, else python. The
# hosted Windows images put python.exe on PATH, and their python3 may be the
# Microsoft Store stub, which exits non-zero. Return 1 when there is none.
playwright_python() {
	local candidate
	for candidate in python3 python; do
		if command -v "$candidate" >/dev/null 2>&1 &&
			"$candidate" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}

# Run scripts/ci/lib/playwright_browsers.py (#1433) with its arguments; stdin
# passes through. Without a usable interpreter it warns and returns 3, which
# every caller reads as "do not know": no cache key, not present, undecided.
playwright_browsers_py() {
	local py
	if ! py="$(playwright_python)"; then
		log_warn "No Python 3.10+ (python3 or python) on PATH; the browser cache and dependency checks are skipped"
		return 3
	fi
	"$py" -I "$_PLAYWRIGHT_RUNNER_LIB_DIR/../playwright_browsers.py" "$@"
}

# Return 0 on a Windows runner (RUNNER_OS, else uname under Git Bash or MSYS).
playwright_runner_is_windows() {
	case "${RUNNER_OS:-$(uname -s)}" in
	Windows | MINGW* | MSYS* | CYGWIN*) return 0 ;;
	esac
	return 1
}

# Print the seconds left of the install budget of the running
# playwright_install_browsers call (a large number outside one).
playwright_install_left() {
	if [[ -z "${_PLAYWRIGHT_INSTALL_DEADLINE:-}" ]]; then
		printf '%s' 999999
		return 0
	fi
	printf '%s' "$((_PLAYWRIGHT_INSTALL_DEADLINE - SECONDS))"
}

# Print min(<wanted>, <fit>), the seconds a bounded stage may run; fail with
# one ::error:: naming <stage> when that is below PLAYWRIGHT_STAGE_MIN_SECONDS
# (#1433). <fit> is what the stage can use of the budget left.
# Usage: playwright_stage_seconds <wanted> <fit> <stage>
playwright_stage_seconds() {
	local wanted="$1" fit="$2" stage="$3"
	if ((fit < wanted)); then
		wanted="$fit"
	fi
	if ((wanted < PLAYWRIGHT_STAGE_MIN_SECONDS)); then
		echo "::error title=Playwright install::no time left for ${stage}:" \
			"the browser install used up its ${_PLAYWRIGHT_INSTALL_BUDGET:-$PLAYWRIGHT_INSTALL_BUDGET_DEFAULT}s budget" >&2
		return 124
	fi
	printf '%s' "$wanted"
}

# Print the kill grace of every bounded attempt.
playwright_kill_grace() {
	printf '%s' "${PLAYWRIGHT_INSTALL_KILL_GRACE_SECONDS:-$PLAYWRIGHT_INSTALL_KILL_GRACE_DEFAULT}"
}

# Run a browser download (`install ...`) through playwright_install_with_retry,
# each attempt cut so both attempts and their kill graces end within the
# install budget (#1433). Invalid timeout values pass through unchanged for
# playwright_install_with_retry to refuse.
# Usage: playwright_install_within_budget <launcher...> install [args...]
playwright_install_within_budget() {
	local grace seconds="${PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS:-$PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT}"
	grace="$(playwright_kill_grace)"
	if [[ "$seconds" =~ ^[1-9][0-9]*$ && "$grace" =~ ^[1-9][0-9]*$ ]]; then
		seconds="$(playwright_stage_seconds "$seconds" \
			"$(($(playwright_install_left) / 2 - grace))" "the browser download")" || return $?
	fi
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS="$seconds" playwright_install_with_retry "$@"
}

# Run <command...> once, bounded by <seconds> plus the kill grace; print an
# ::error:: naming <what> when the deadline fired. Returns its exit code.
# Usage: playwright_bounded_once <seconds> <what> <command...>
playwright_bounded_once() {
	local seconds="$1" what="$2" grace fired rc=0
	shift 2
	grace="$(playwright_kill_grace)"
	fired="$(mktemp "${TMPDIR:-/tmp}/playwright-stage.XXXXXX")" || return 2
	playwright_bounded_run "$seconds" "$grace" "$fired" "$@" || rc=$?
	if [[ -n "$(cat "$fired")" ]]; then
		echo "::error title=Playwright install::${what} timed out after ${seconds}s" >&2
	fi
	rm -f "$fired"
	return "$rc"
}

# Run one bounded, budget-cut stage: `playwright <args...>` that downloads
# nothing (a dry run, or install-deps). Usage:
# playwright_bounded_stage <wanted-seconds> <what> <launcher...> <args...>
playwright_bounded_stage() {
	local wanted="$1" what="$2" seconds grace
	shift 2
	grace="$(playwright_kill_grace)"
	seconds="$(playwright_stage_seconds "$wanted" \
		"$(($(playwright_install_left) - grace))" "$what")" || return $?
	playwright_bounded_once "$seconds" "$what" "$@"
}

# Run the shared apt helper (#1432) with its run budget cut to what is left of
# the install budget (#1433). A caller's LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS
# replaces the default (and is cut the same way); a non-integer one goes to
# the helper to refuse.
# Usage: playwright_apt_helper <helper args...>
playwright_apt_helper() {
	local seconds="${LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS:-$PLAYWRIGHT_APT_TIMEOUT_DEFAULT}"
	if [[ "$seconds" =~ ^[0-9]+$ ]]; then
		seconds="$(playwright_stage_seconds "$seconds" "$(playwright_install_left)" \
			"the apt helper's $1 run")" || return $?
	fi
	LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS="$seconds" \
		python3 -I "$_PLAYWRIGHT_RUNNER_LIB_DIR/../apt_helper.py" "$@"
}

# Install the Linux system packages Playwright reports through the shared apt
# helper (#1432): `apt_helper.py update`, `playwright install-deps --dry-run`
# (bounded, parsed by playwright_deps.py), then `apt_helper.py install
# --no-update --no-install-recommends`. When the dry run is not recognised:
# with the browsers already on disk (<on-disk> 1), one bounded `playwright
# install-deps` installs the packages without downloading again (#1433);
# otherwise `install --with-deps` (which also downloads) runs. Sets
# PLAYWRIGHT_DEPS_FELL_BACK to 0 (helper), 1 (`install --with-deps`, the
# browsers are then installed too) or 2 (`install-deps`).
# Usage: playwright_install_system_packages <browsers|all> <install-args> <on-disk> <launcher...>
#   install-args - space-separated arguments for the --with-deps fallback
playwright_install_system_packages() {
	local browsers="$1" install_args="$2" on_disk="$3"
	shift 3
	local -a names=() packages=() fallback=()
	[[ "$browsers" == "all" ]] || read -ra names <<<"$browsers"
	read -ra fallback <<<"$install_args"
	PLAYWRIGHT_DEPS_FELL_BACK=0
	local dry_run="" dry_rc=0 parsed=""
	playwright_apt_helper update || return $?
	dry_run="$(playwright_bounded_stage "$PLAYWRIGHT_DRY_RUN_TIMEOUT_DEFAULT" \
		"playwright install-deps --dry-run" \
		"$@" install-deps --dry-run ${names[@]+"${names[@]}"} 2>&1)" || dry_rc=$?
	if ! parsed="$(printf '%s\n' "$dry_run" |
		python3 -I "$_PLAYWRIGHT_RUNNER_LIB_DIR/../playwright_deps.py" --exit-code "$dry_rc")"; then
		if ((on_disk)); then
			echo "::warning title=Playwright system packages::playwright install-deps --dry-run output was not recognised; falling back to playwright install-deps (the browsers are already on disk), which runs apt without the shared helper's timeouts and retries"
			PLAYWRIGHT_DEPS_FELL_BACK=2
			playwright_bounded_stage "$PLAYWRIGHT_INSTALL_DEPS_TIMEOUT_DEFAULT" "playwright install-deps" \
				"$@" install-deps ${names[@]+"${names[@]}"}
			return
		fi
		echo "::warning title=Playwright system packages::playwright install-deps --dry-run output was not recognised; falling back to playwright install --with-deps, which runs apt without the shared helper's timeouts and retries"
		PLAYWRIGHT_DEPS_FELL_BACK=1
		playwright_install_within_budget "$@" install --with-deps ${fallback[@]+"${fallback[@]}"}
		return
	fi
	read -ra packages <<<"$(printf '%s' "$parsed" | tr '\n' ' ')"
	if [[ ${#packages[@]} -gt 0 ]]; then
		log_info "Installing ${#packages[@]} Playwright system packages through the apt helper..."
		# The lists were refreshed by the helper's update above.
		playwright_apt_helper install --no-update --no-install-recommends "${packages[@]}" || return $?
	else
		log_info "Playwright reports every system package installed"
	fi
}

# Print the stdout of `playwright install --dry-run <install-args>` (bounded):
# one record per artifact the real install puts down, for
# playwright_browsers.py present / probe, which read it all or nothing
# (playwright_dry_run.py). Playwright prints the records on stdout; stderr
# (package-manager notices, Playwright's npx warning box, a timeout
# annotation) goes to the step log, so it can neither pass for a record nor
# spoil a recognised list. Callers treat unrecognised output as "not present"
# and "undecided".
# Usage: playwright_install_locations <install-args> <launcher...>
playwright_install_locations() {
	local -a args=()
	read -ra args <<<"$1"
	shift
	playwright_bounded_stage "$PLAYWRIGHT_DRY_RUN_TIMEOUT_DEFAULT" "playwright install --dry-run" \
		"$@" install --dry-run ${args[@]+"${args[@]}"}
}

# Return 0 when <path> is absolute: /... or, on Windows, a drive (C:\ or C:/).
playwright_path_is_absolute() {
	[[ "${1:-}" == /* || "${1:-}" =~ ^[A-Za-z]:[\\/] ]]
}

# Immediately before the install, on a miss, record whether the browser
# directory is clean (#1659): absent, or an empty directory. The directory is
# the absolute path playwright_browsers.py cache-path resolves here, in the
# install's own working directory, as the install resolves it, and it must be
# BROWSER_CACHE_PATH, the path the cache steps restore into and save from.
# Sets _PLAYWRIGHT_CACHE_CLEAN=1 only then. Anything else leaves it 0, so the
# browser cache is not saved: files a failed or partial restore left, a
# directory filled before the install, a symlink, a relative or different
# path, no Python. The install itself proceeds as it always did. This only
# reads: nothing is removed.
playwright_record_cache_dir_state() {
	_PLAYWRIGHT_CACHE_CLEAN=0
	local path="${BROWSER_CACHE_PATH:-}" resolved="" entry=""
	[[ -n "$path" && "${BROWSER_CACHE_HIT:-}" != "true" ]] || return 0
	resolved="$(playwright_browsers_py cache-path </dev/null)" || resolved=""
	if [[ -z "$resolved" || "$resolved" != "$path" ]] || ! playwright_path_is_absolute "$resolved"; then
		log_warn "The browser cache path '${path}' is not the absolute browser directory the install uses ('${resolved}'); the browser cache is not saved"
		return 0
	fi
	if [[ -L "$resolved" ]]; then
		log_info "The browser directory ${resolved} is a symlink; the browser cache is not saved"
		return 0
	fi
	if [[ -e "$resolved" ]]; then
		if [[ ! -d "$resolved" ]] ||
			! entry="$(find "$resolved" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ||
			[[ -n "$entry" ]]; then
			log_info "The browser directory ${resolved} is not empty before the install (files from a failed or partial restore, or put there earlier); the install proceeds, and the browser cache is not saved"
			return 0
		fi
	fi
	_PLAYWRIGHT_CACHE_CLEAN=1
}

# After a successful install, on a miss, set PLAYWRIGHT_BROWSERS_READY=true
# when the save may run (#1659): the directory was clean immediately before
# the install (playwright_record_cache_dir_state) and every artifact `playwright install
# --dry-run` lists for the same arguments holds its INSTALLATION_COMPLETE
# marker (playwright_browsers.py present, the check a hit relies on). The dry
# run is cut to what is left of the install budget; no time left, a failed
# dry run or an incomplete artifact leaves it false. Never fails the install.
# Usage: playwright_check_browsers_ready <browsers|all> <launcher...>
playwright_check_browsers_ready() {
	local browsers="$1" mode locations grace
	shift
	PLAYWRIGHT_BROWSERS_READY=false
	[[ -n "${BROWSER_CACHE_PATH:-}" && "${BROWSER_CACHE_HIT:-}" != "true" ]] || return 0
	[[ "${_PLAYWRIGHT_CACHE_CLEAN:-0}" == 1 ]] || return 0
	mode="$(playwright_install_option BROWSER_INSTALL_MODE full full headless-shell)" || return 0
	local -a names=() install_args=()
	[[ "$browsers" == "all" ]] || read -ra names <<<"$browsers"
	[[ "$mode" == "headless-shell" ]] && install_args+=(--only-shell)
	install_args+=(${names[@]+"${names[@]}"})
	grace="$(playwright_kill_grace)"
	if (($(playwright_install_left) - grace < PLAYWRIGHT_STAGE_MIN_SECONDS)); then
		log_info "No install budget left to check the installed browsers; the browser cache is not saved"
		return 0
	fi
	locations="$(playwright_install_locations "${install_args[*]-}" "$@")" || locations=""
	if [[ -n "$locations" ]] && printf '%s\n' "$locations" | playwright_browsers_py present; then
		PLAYWRIGHT_BROWSERS_READY=true
		log_info "Every installed browser artifact is complete; the browser cache may be saved"
	else
		log_warn "Not every browser artifact the install lists is complete after the install; the browser cache is not saved"
	fi
	return 0
}

# Install Playwright browsers (#1432, #1433).
#
# Every bounded stage shares one budget, PLAYWRIGHT_INSTALL_BUDGET_SECONDS
# (default PLAYWRIGHT_INSTALL_BUDGET_DEFAULT): each is cut to what is left, so
# no path runs past it, whichever branch it takes.
#
# Browser download: skipped when BROWSER_CACHE_HIT is `true` (the browser
# cache restored its exact key: OS release, architecture, Playwright version,
# install mode, browsers) and every artifact `playwright install --dry-run`
# lists for the same arguments (the browser, chromium's headless shell,
# FFmpeg, at the revisions this Playwright expects) holds its
# INSTALLATION_COMPLETE marker; otherwise `playwright install` runs through
# playwright_install_with_retry (#1563). BROWSER_INSTALL_MODE=headless-shell
# adds `--only-shell` (chromium's headless shell instead of the full browser).
#
# System packages: on Linux,
#   BROWSER_SYSTEM_DEPS=always (the default): the shared apt helper installs
#     what `playwright install-deps --dry-run` reports, before the download,
#     as since #1432 (see playwright_install_system_packages).
#   BROWSER_SYSTEM_DEPS=if-missing: the browsers are downloaded first (when
#     needed), then playwright_browsers.py `probe` runs `ldd` on every listed
#     artifact. Only when it reports a missing library, or cannot decide
#     (exit 3: WebKit, which loads libraries with dlopen; no ldd; an artifact
#     missing; ldd failed; no time left), do the system packages install as
#     above, with `playwright install-deps` (no second download) as the
#     fallback. ldd sees shared libraries only; fonts and xvfb are not probed.
# On Windows a skipped download still runs Playwright's own dependency step,
# `playwright install-deps` (bounded); macOS has none. Off a cache hit both
# keep `install --with-deps`, which never calls apt there.
#
# Browser cache (#1659), when BROWSER_CACHE_PATH names the directory the
# cache steps restore into and save from:
#   Immediately before the install, on a miss (BROWSER_CACHE_HIT not
#     `true`), playwright_record_cache_dir_state records whether the
#     directory is absent or empty. Nothing is ever removed.
#   After the install, on a miss, playwright_check_browsers_ready runs the
#     completeness check a hit relies on, inside the same budget, and sets
#     PLAYWRIGHT_BROWSERS_READY=true only when it passes on a directory that
#     was clean before the install. The save step runs only then.
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
	PLAYWRIGHT_BROWSERS_READY=false
	local _PLAYWRIGHT_INSTALL_BUDGET="${PLAYWRIGHT_INSTALL_BUDGET_SECONDS:-$PLAYWRIGHT_INSTALL_BUDGET_DEFAULT}"
	if [[ ! "$_PLAYWRIGHT_INSTALL_BUDGET" =~ ^[1-9][0-9]*$ ]]; then
		log_error "PLAYWRIGHT_INSTALL_BUDGET_SECONDS must be a positive integer (got '${_PLAYWRIGHT_INSTALL_BUDGET}')"
		return 2
	fi
	local _PLAYWRIGHT_INSTALL_DEADLINE=$((SECONDS + _PLAYWRIGHT_INSTALL_BUDGET))
	local _PLAYWRIGHT_CACHE_CLEAN=0
	playwright_record_cache_dir_state
	_playwright_install_browsers_run "$browsers" "$@" || return $?
	playwright_check_browsers_ready "$browsers" "$@"
}

# The install itself (see playwright_install_browsers, which sets the budget).
# Usage: _playwright_install_browsers_run <browsers|all> <launcher...>
_playwright_install_browsers_run() {
	local browsers="$1"
	shift
	local system_deps mode started=$SECONDS download=1 rc=0
	system_deps="$(playwright_install_option BROWSER_SYSTEM_DEPS always always if-missing)" || return 2
	mode="$(playwright_install_option BROWSER_INSTALL_MODE full full headless-shell)" || return 2
	local -a names=() install_args=() missing=()
	[[ "$browsers" == "all" ]] || read -ra names <<<"$browsers"
	[[ "$mode" == "headless-shell" ]] && install_args+=(--only-shell)
	install_args+=(${names[@]+"${names[@]}"})
	local locations="" browser_state="downloaded" deps_state="not needed off Linux"

	if [[ "${BROWSER_CACHE_HIT:-}" == "true" ]]; then
		locations="$(playwright_install_locations "${install_args[*]-}" "$@")" || locations=""
		if printf '%s\n' "$locations" | playwright_browsers_py present; then
			download=0
			browser_state="restored from the cache (exact key), download skipped"
		else
			log_info "The browser cache was restored, but not every artifact the install lists is complete; installing"
			locations=""
		fi
	fi

	if ! playwright_runner_is_linux; then
		if ((download)); then
			playwright_install_within_budget "$@" install --with-deps ${install_args[@]+"${install_args[@]}"} || return $?
		elif playwright_runner_is_windows; then
			playwright_bounded_stage "$PLAYWRIGHT_INSTALL_DEPS_TIMEOUT_DEFAULT" "playwright install-deps" \
				"$@" install-deps ${names[@]+"${names[@]}"} || return $?
			deps_state="checked by playwright install-deps"
		fi
		log_info "Playwright install: browsers ${browser_state}; system packages ${deps_state} ($((SECONDS - started))s)"
		return 0
	fi

	if [[ "$system_deps" == "if-missing" ]]; then
		if ((download)); then
			playwright_install_within_budget "$@" install ${install_args[@]+"${install_args[@]}"} || return $?
			download=0
		fi
		[[ -n "$locations" ]] || locations="$(playwright_install_locations "${install_args[*]-}" "$@")" || locations=""
		# The probe stops starting ldd calls after its budget and each call
		# may take 30s more (playwright_ldd.py): keep 40s of the budget back.
		local probe_out="" probe_rc=0 probe_budget=$(($(playwright_install_left) - 40))
		if ((probe_budget > 60)); then
			probe_budget=60
		fi
		if ((probe_budget >= 1)); then
			probe_out="$(printf '%s\n' "$locations" |
				playwright_browsers_py probe --budget-seconds "$probe_budget")" || probe_rc=$?
		else
			probe_rc=3
		fi
		case "$probe_rc" in
		0)
			log_info "Playwright install: browsers ${browser_state}; system packages present (ldd found every library), apt skipped ($((SECONDS - started))s)"
			return 0
			;;
		1)
			read -ra missing <<<"$(printf '%s' "$probe_out" | tr '\n' ' ')"
			log_info "ldd reports ${#missing[@]} missing libraries (${missing[*]}); installing the system packages"
			;;
		*)
			log_warn "Could not tell whether the browsers' system libraries are present (probe exit ${probe_rc}); installing the system packages"
			;;
		esac
	fi

	playwright_install_system_packages "$browsers" "${install_args[*]-}" "$((1 - download))" "$@" || rc=$?
	((rc == 0)) || return "$rc"
	case "$PLAYWRIGHT_DEPS_FELL_BACK" in
	1) deps_state="installed by playwright install --with-deps" ;;
	2) deps_state="installed by playwright install-deps" ;;
	*)
		deps_state="installed through the apt helper"
		if ((download)); then
			playwright_install_within_budget "$@" install ${install_args[@]+"${install_args[@]}"} || return $?
		fi
		;;
	esac
	log_info "Playwright install: browsers ${browser_state}; system packages ${deps_state} ($((SECONDS - started))s)"
}
