#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/playwright_runner.sh (#1313):
#          minimum @playwright/test on Ubuntu 26.04.

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
	source "${PROJECT_ROOT}/scripts/ci/lib/testing/playwright_runner.sh"
}

teardown() {
	teardown_temp_dir
}

_os() {
	printf 'ID=%s\nVERSION_ID="%s"\n' "$1" "$2" >"$OS_RELEASE_FILE"
}

@test "playwright_runner: minimum constant is 1.61" {
	assert_equal "$PLAYWRIGHT_MIN_VERSION_UBUNTU_2604" "1.61"
}

@test "playwright_runner: 26.04 below the minimum fails with the message" {
	_os ubuntu 26.04
	run check_playwright_runner_support 1.55.0
	assert_failure
	assert_output --partial "::error::@playwright/test 1.55.0"
	assert_output --partial "1.61 or newer is required"
	assert_output --partial "runner-image: ubuntu-24.04"
}

@test "playwright_runner: 26.04 at or above the minimum passes" {
	_os ubuntu 26.04
	run check_playwright_runner_support 1.61.0
	assert_success
	assert_output ""
	run check_playwright_runner_support 2.0.0
	assert_success
	run check_playwright_runner_support 1.100.0
	assert_success
}

@test "playwright_runner: prerelease versions compare on major.minor" {
	_os ubuntu 26.04
	run check_playwright_runner_support 1.62.0-alpha-2026-01-01
	assert_success
	run check_playwright_runner_support 1.60.0-beta
	assert_failure
}

@test "playwright_runner: 24.04 below the minimum passes" {
	_os ubuntu 24.04
	run check_playwright_runner_support 1.55.0
	assert_success
	assert_output ""
}

@test "playwright_runner: non-Ubuntu 26.04 VERSION_ID is ignored" {
	_os debian 26.04
	run check_playwright_runner_support 1.55.0
	assert_success
}

@test "playwright_runner: missing os-release skips the check" {
	rm -f "$OS_RELEASE_FILE"
	run check_playwright_runner_support 1.55.0
	assert_success
}

@test "playwright_runner: 26.04 with an unresolvable version warns and continues" {
	_os ubuntu 26.04
	run check_playwright_runner_support unknown
	assert_success
	assert_output --partial "::warning::"
	assert_output --partial "1.61"
	run check_playwright_runner_support ""
	assert_success
	assert_output --partial "::warning::"
}

# playwright_install_browsers (#1432). On Linux the apt helper installs the
# packages that `install-deps --dry-run` reports (parsed by the real
# playwright_deps.py); macOS and Windows keep `install --with-deps`.
# Fixtures: tests/fixtures/playwright-deps (see tests/python/test_playwright_deps.py).

FIXTURES="${PROJECT_ROOT}/tests/fixtures/playwright-deps"

# Mock the apt helper (records; `update` exits $MOCK_APT_EXIT, `install`
# prints $MOCK_APT_INSTALL_OUTPUT and exits $MOCK_APT_INSTALL_EXIT) while running the real
# dry-run parser, and a Playwright launcher `pw` whose dry run prints
# $DRY_RUN_FILE and exits $DRY_RUN_EXIT.
_mock_install_tools() {
	local bin="${BATS_TEST_TMPDIR}/bin" real_python
	real_python="$(command -v python3)"
	mkdir -p "$bin"
	cat >"${bin}/python3" <<MOCK
#!/usr/bin/env bash
if [[ "\$2" == */apt_helper.py ]]; then
	echo "\${*:3}" >>"${BATS_TEST_TMPDIR}/calls_apt"
	echo "\${LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS:-unset}" >>"${BATS_TEST_TMPDIR}/apt_budget"
	if [[ "\$3" == install ]]; then
		echo "\${MOCK_APT_INSTALL_OUTPUT:-}"
		exit \${MOCK_APT_INSTALL_EXIT:-0}
	fi
	exit \${MOCK_APT_EXIT:-0}
fi
exec "${real_python}" "\$@"
MOCK
	cat >"${bin}/pw" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"${BATS_TEST_TMPDIR}/calls_pw"
if [[ " $* " == *" install-deps "* ]]; then
	cat "${DRY_RUN_FILE:-/dev/null}"
	exit "${DRY_RUN_EXIT:-0}"
fi
exit 0
MOCK
	chmod +x "${bin}/python3" "${bin}/pw"
	: >"${BATS_TEST_TMPDIR}/calls_apt"
	: >"${BATS_TEST_TMPDIR}/calls_pw"
	PATH="${bin}:${PATH}"
}

_apt_calls() { cat "${BATS_TEST_TMPDIR}/calls_apt"; }
_apt_budgets() { cat "${BATS_TEST_TMPDIR}/apt_budget"; }

@test "playwright_install_browsers: both apt helper runs get the Playwright budget (#1571)" {
	_mock_install_tools
	export DRY_RUN_FILE="${FIXTURES}/dry-run-1.63.0-missing.txt" DRY_RUN_EXIT=1
	unset LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS
	RUNNER_OS=Linux run playwright_install_browsers "chromium" pw
	assert_success
	run _apt_budgets
	assert_output "$(printf '%s\n' "$PLAYWRIGHT_APT_TIMEOUT_DEFAULT" "$PLAYWRIGHT_APT_TIMEOUT_DEFAULT")"
	assert_equal "$PLAYWRIGHT_APT_TIMEOUT_DEFAULT" "300"
}

@test "playwright_install_browsers: a caller's apt budget wins (#1571)" {
	_mock_install_tools
	export DRY_RUN_FILE="${FIXTURES}/dry-run-1.63.0-missing.txt" DRY_RUN_EXIT=1
	LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS=120 RUNNER_OS=Linux run playwright_install_browsers "chromium" pw
	assert_success
	run _apt_budgets
	assert_output "$(printf '%s\n' 120 120)"
}
_pw_calls() { cat "${BATS_TEST_TMPDIR}/calls_pw"; }

@test "playwright_install_browsers: Linux 1.63 dry run installs the missing packages through the helper" {
	_mock_install_tools
	export DRY_RUN_FILE="${FIXTURES}/dry-run-1.63.0-missing.txt" DRY_RUN_EXIT=1
	RUNNER_OS=Linux run playwright_install_browsers "chromium" pw --flag
	assert_success
	refute_output --partial "::warning"
	run _apt_calls
	assert_line --index 0 "update"
	assert_line --index 1 --regexp '^install --no-update --no-install-recommends fonts-freefont-ttf fonts-ipafont-gothic .* xvfb$'
	assert_equal "$(wc -w <<<"${lines[1]}" | tr -d ' ')" "36"
	run _pw_calls
	assert_line --index 0 "--flag install-deps --dry-run chromium"
	assert_line --index 1 "--flag install chromium"
	refute_output --partial "--with-deps"
}

@test "playwright_install_browsers: Linux 1.56 command-format dry run is parsed too" {
	_mock_install_tools
	export DRY_RUN_FILE="${FIXTURES}/dry-run-1.56.0-command.txt" DRY_RUN_EXIT=0
	RUNNER_OS=Linux run playwright_install_browsers "chromium firefox" pw
	assert_success
	run _apt_calls
	assert_line --index 1 --regexp '^install --no-update --no-install-recommends libasound2t64 libatk-bridge2\.0-0t64 .* xfonts-scalable'
	assert_equal "$(_pw_calls | tail -n 1)" "install chromium firefox"
}

@test "playwright_install_browsers: Linux with every package installed skips apt install" {
	_mock_install_tools
	export DRY_RUN_FILE="${FIXTURES}/dry-run-1.63.0-all-installed.txt" DRY_RUN_EXIT=0
	RUNNER_OS=Linux run playwright_install_browsers all pw
	assert_success
	assert_equal "$(_apt_calls)" "update"
	run _pw_calls
	assert_line --index 0 "install-deps --dry-run"
	assert_line --index 1 "install"
}

@test "playwright_install_browsers: unrecognised dry run warns and falls back to --with-deps" {
	_mock_install_tools
	printf 'Error: something unexpected\n' >"${BATS_TEST_TMPDIR}/odd.txt"
	export DRY_RUN_FILE="${BATS_TEST_TMPDIR}/odd.txt" DRY_RUN_EXIT=1
	RUNNER_OS=Linux run playwright_install_browsers chromium pw
	assert_success
	assert_output --partial "::warning title=Playwright system packages::playwright install-deps --dry-run output was not recognised"
	assert_equal "$(_apt_calls)" "update"
	assert_equal "$(_pw_calls | tail -n 1)" "install --with-deps chromium"
}

@test "playwright_install_browsers: an invalid package name falls back, never reaches apt" {
	_mock_install_tools
	local evil
	# A leading "-" is an option, a trailing "-" means remove, "=" pins a version.
	for evil in "-oDPkg::Pre-Invoke=x" "curl-" "foo=1.0" "foo/resolute" "foo:amd64"; do
		printf 'Missing system dependencies (2):\n  libnss3\n  %s\n' "$evil" >"${BATS_TEST_TMPDIR}/evil.txt"
		: >"${BATS_TEST_TMPDIR}/calls_apt"
		: >"${BATS_TEST_TMPDIR}/calls_pw"
		export DRY_RUN_FILE="${BATS_TEST_TMPDIR}/evil.txt" DRY_RUN_EXIT=1
		RUNNER_OS=Linux run playwright_install_browsers chromium pw
		assert_success
		assert_output --partial "::warning title=Playwright system packages::"
		assert_equal "$(_apt_calls)" "update"
		assert_equal "$(_pw_calls | tail -n 1)" "install --with-deps chromium"
	done
}

@test "playwright_install_browsers: g++ (a trailing +) is a valid package name" {
	_mock_install_tools
	printf 'Missing system dependencies (2):\n  g++\n  libnss3\n' >"${BATS_TEST_TMPDIR}/gpp.txt"
	export DRY_RUN_FILE="${BATS_TEST_TMPDIR}/gpp.txt" DRY_RUN_EXIT=1
	RUNNER_OS=Linux run playwright_install_browsers chromium pw
	assert_success
	refute_output --partial "::warning"
	assert_equal "$(_apt_calls | tail -n 1)" "install --no-update --no-install-recommends g++ libnss3"
}

@test "playwright_install_browsers: a failing apt update stops before Playwright runs" {
	_mock_install_tools
	MOCK_APT_EXIT=100 RUNNER_OS=Linux run playwright_install_browsers chromium pw
	assert_failure 100
	assert_equal "$(_pw_calls)" ""
}

@test "playwright_install_browsers: a failing apt install stops before the browser install" {
	_mock_install_tools
	export DRY_RUN_FILE="${FIXTURES}/dry-run-1.63.0-missing.txt" DRY_RUN_EXIT=1
	export MOCK_APT_INSTALL_EXIT=100
	export MOCK_APT_INSTALL_OUTPUT="::error::apt could not reach a package mirror (DNS or network failure) after all retries"
	RUNNER_OS=Linux run playwright_install_browsers chromium pw
	assert_failure 100
	assert_output --partial "::error::apt could not reach a package mirror"
	run _pw_calls
	assert_output "install-deps --dry-run chromium"
}

@test "playwright_install_browsers: macOS keeps install --with-deps without the helper" {
	_mock_install_tools
	RUNNER_OS=macOS run playwright_install_browsers webkit pw
	assert_success
	assert_equal "$(_apt_calls)" ""
	assert_equal "$(_pw_calls)" "install --with-deps webkit"
}

@test "playwright_install_browsers: Windows keeps install --with-deps without the helper" {
	_mock_install_tools
	RUNNER_OS=Windows run playwright_install_browsers all pw
	assert_success
	assert_equal "$(_apt_calls)" ""
	assert_equal "$(_pw_calls)" "install --with-deps"
}

@test "playwright_install_browsers: without RUNNER_OS, uname decides" {
	_mock_install_tools
	cat >"${BATS_TEST_TMPDIR}/bin/uname" <<'MOCK'
#!/usr/bin/env bash
echo Darwin
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/bin/uname"
	unset RUNNER_OS
	run playwright_install_browsers chromium pw
	assert_success
	assert_equal "$(_pw_calls)" "install --with-deps chromium"
}

@test "playwright_install_browsers: a launcher is required" {
	run playwright_install_browsers chromium
	assert_failure 2
}

# playwright_install_with_retry (#1563): each browser download attempt runs
# under coreutils timeout (or the bash watchdog without it) and a failed or
# timed-out attempt is retried once.

# A launcher `pwr` whose `install` fails (or hangs) for the first
# $MOCK_PW_FAILURES calls; $MOCK_PW_MODE is "exit" (exit 3) or "hang".
_mock_flaky_install() {
	local bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$bin"
	cat >"${bin}/pwr" <<'MOCK'
#!/usr/bin/env bash
count_file="${BATS_TEST_TMPDIR}/pwr_count"
n=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
echo "$n" >"$count_file"
echo "$*" >>"${BATS_TEST_TMPDIR}/calls_pwr"
if ((n <= ${MOCK_PW_FAILURES:-0})); then
	[[ "${MOCK_PW_MODE:-exit}" == hang ]] && exec sleep 30
	exit 3
fi
exit 0
MOCK
	chmod +x "${bin}/pwr"
	: >"${BATS_TEST_TMPDIR}/calls_pwr"
	PATH="${bin}:${PATH}"
}

_pwr_calls() { cat "${BATS_TEST_TMPDIR}/calls_pwr"; }

@test "playwright_install_with_retry: a first success runs once, silently" {
	_mock_flaky_install
	run playwright_install_with_retry pwr install chromium
	assert_success
	refute_output --partial "::"
	assert_equal "$(_pwr_calls)" "install chromium"
}

@test "playwright_install_with_retry: one failure warns and retries" {
	_mock_flaky_install
	MOCK_PW_FAILURES=1 run playwright_install_with_retry pwr install chromium
	assert_success
	assert_output --partial \
		"::warning title=Playwright browser install::attempt 1 failed (exit 3); retrying once"
	refute_output --partial "::error::"
	assert_equal "$(_pwr_calls | wc -l | tr -d ' ')" "2"
}

@test "playwright_install_with_retry: one timeout warns and retries" {
	_mock_flaky_install
	MOCK_PW_FAILURES=1 MOCK_PW_MODE=hang PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 \
		run playwright_install_with_retry pwr install chromium
	assert_success
	assert_output --partial \
		"::warning title=Playwright browser install::attempt 1 timed out after 1s; retrying once"
	refute_output --partial "::error::"
}

@test "playwright_install_with_retry: two timeouts print the canary signature" {
	_mock_flaky_install
	MOCK_PW_FAILURES=2 MOCK_PW_MODE=hang PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 \
		run playwright_install_with_retry pwr install chromium
	assert_failure 124
	assert_equal "$(grep -c '::error::' <<<"$output")" "1"
	assert_output --partial \
		"::error::Playwright browser install timed out twice (1s per attempt)"
	assert_equal "$(_pwr_calls | wc -l | tr -d ' ')" "2"
}

@test "playwright_install_with_retry: two errors print the non-signature error" {
	_mock_flaky_install
	MOCK_PW_FAILURES=2 run playwright_install_with_retry pwr install chromium
	assert_failure 3
	assert_equal "$(grep -c '::error::' <<<"$output")" "1"
	assert_output --partial \
		"::error::Playwright browser install failed twice (timeout or error)"
}

@test "playwright_install_with_retry: a timeout then an error is not the timeout signature" {
	_mock_flaky_install
	cat >"${BATS_TEST_TMPDIR}/bin/pwr" <<'MOCK'
#!/usr/bin/env bash
count_file="${BATS_TEST_TMPDIR}/pwr_count"
n=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
echo "$n" >"$count_file"
((n == 1)) && exec sleep 30
exit 3
MOCK
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 run playwright_install_with_retry pwr install chromium
	assert_failure 3
	assert_output --partial \
		"::error::Playwright browser install failed twice (timeout or error)"
	refute_output --partial "timed out twice"
}

@test "playwright_install_with_retry: an invalid timeout is refused before running" {
	_mock_flaky_install
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=0 run playwright_install_with_retry pwr install
	assert_failure 2
	assert_equal "$(_pwr_calls)" ""
	run playwright_install_with_retry
	assert_failure 2
}

@test "playwright_install_with_retry: an immediate exit 124 is an error, not a timeout" {
	_mock_install_script 'exit 124'
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=5 run playwright_install_with_retry pwr install chromium
	assert_failure 124
	assert_output --partial "attempt 1 failed (exit 124); retrying once"
	assert_output --partial "::error::Playwright browser install failed twice (timeout or error)"
	refute_output --partial "timed out"
	assert_equal "$(_pwr_calls | wc -l | tr -d ' ')" "2"
}

@test "playwright_install_with_retry: an immediate SIGKILL (OOM) is an error, not a timeout" {
	_mock_install_script 'kill -KILL $$'
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=5 run playwright_install_with_retry pwr install chromium
	assert_failure 137
	assert_output --partial "attempt 1 failed (exit 137); retrying once"
	assert_output --partial "::error::Playwright browser install failed twice (timeout or error)"
	refute_output --partial "timed out"
}

# The hosted macOS images ship no coreutils timeout: the bash watchdog bounds
# each attempt instead. Non-coreutils `timeout`/`gtimeout` first on PATH hide
# any real one.
_hide_coreutils_timeout() {
	local bin="${BATS_TEST_TMPDIR}/nocoreutils"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\necho "ERROR: Invalid syntax."\nexit 1\n' >"${bin}/timeout"
	cp "${bin}/timeout" "${bin}/gtimeout"
	chmod +x "${bin}/timeout" "${bin}/gtimeout"
	PATH="${bin}:${PATH}"
	run playwright_timeout_bin
	assert_failure
}

# A launcher `pwr` running $1 as its body; every call is logged.
_mock_install_script() {
	_mock_flaky_install
	{
		printf '#!/usr/bin/env bash\n'
		printf 'echo "$*" >>"${BATS_TEST_TMPDIR}/calls_pwr"\n'
		printf '%s\n' "$1"
	} >"${BATS_TEST_TMPDIR}/bin/pwr"
}

# Fail the test when any pid listed in $1 still runs (killing it first). The
# mocks close their sleepers' stdout and stderr: a survivor holding `run`'s
# output open would make `run` wait until it exits by itself.
_assert_all_dead() {
	local pid alive=""
	assert [ -s "$1" ]
	while read -r pid; do
		[[ -n "$pid" ]] || continue
		if kill -0 "$pid" 2>/dev/null; then
			alive+="${pid} "
			kill -KILL "$pid" 2>/dev/null || true
		fi
	done <"$1"
	assert_equal "$alive" ""
}

@test "playwright_install_with_retry: without coreutils timeout the watchdog retries a hang" {
	_hide_coreutils_timeout
	_mock_flaky_install
	MOCK_PW_FAILURES=1 MOCK_PW_MODE=hang PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 \
		run playwright_install_with_retry pwr install chromium
	assert_success
	assert_output --partial \
		"::warning title=Playwright browser install::attempt 1 timed out after 1s; retrying once"
	refute_output --partial "::error::"
	assert_equal "$(_pwr_calls | wc -l | tr -d ' ')" "2"
}

@test "playwright_install_with_retry: the watchdog kills a hung child and grandchild" {
	_hide_coreutils_timeout
	export PIDS="${BATS_TEST_TMPDIR}/pids"
	_mock_install_script 'sleep 30 >&- 2>&- & echo "$!" >>"$PIDS"
(sleep 30) >&- 2>&- & echo "$!" >>"$PIDS"; wait'
	local start=$SECONDS
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 run playwright_install_with_retry pwr install chromium
	assert_failure 124
	assert_equal "$(grep -c '::error::' <<<"$output")" "1"
	assert_output --partial \
		"::error::Playwright browser install timed out twice (1s per attempt)"
	assert_equal "$(_pwr_calls | wc -l | tr -d ' ')" "2"
	assert [ $((SECONDS - start)) -lt 15 ]
	_assert_all_dead "$PIDS"
}

@test "playwright_install_with_retry: the watchdog KILLs a TERM-ignoring attempt" {
	_hide_coreutils_timeout
	export PIDS="${BATS_TEST_TMPDIR}/pids"
	# The ignored TERM is inherited by the backgrounded grandchild.
	_mock_install_script "trap '' TERM; sleep 30 >&- 2>&- & echo \"\$!\" >>\"\$PIDS\"; wait"
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 PLAYWRIGHT_INSTALL_KILL_GRACE_SECONDS=1 \
		run playwright_install_with_retry pwr install chromium
	assert_failure 137
	assert_output --partial "attempt 1 timed out after 1s; retrying once"
	assert_output --partial \
		"::error::Playwright browser install timed out twice (1s per attempt)"
	assert_equal "$(_pwr_calls | wc -l | tr -d ' ')" "2"
	_assert_all_dead "$PIDS"
}

@test "playwright_install_with_retry: a grandchild ignoring TERM dies with the attempt" {
	_hide_coreutils_timeout
	export PIDS="${BATS_TEST_TMPDIR}/pids"
	# The parent dies on TERM; its grandchild ignores TERM and would outlive it.
	_mock_install_script "(trap '' TERM; exec sleep 30) >&- 2>&- &
echo \"\$!\" >>\"\$PIDS\"; wait"
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 run playwright_install_with_retry pwr install chromium
	assert_failure 124
	assert_output --partial \
		"::error::Playwright browser install timed out twice (1s per attempt)"
	_assert_all_dead "$PIDS"
}

@test "playwright_install_with_retry: coreutils timeout also kills a TERM-ignoring grandchild" {
	# GNU timeout returns as soon as its direct child dies on TERM and never
	# sends KILL; the group must still be cleaned up (Sol, Opus on #1563).
	playwright_timeout_bin >/dev/null || skip "no coreutils timeout on this host"
	export PIDS="${BATS_TEST_TMPDIR}/pids"
	_mock_install_script "(trap '' TERM; exec sleep 30) >&- 2>&- &
echo \"\$!\" >>\"\$PIDS\"; wait"
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 run playwright_install_with_retry pwr install chromium
	assert_failure 124
	assert_output --partial \
		"::error::Playwright browser install timed out twice (1s per attempt)"
	_assert_all_dead "$PIDS"
}

@test "playwright_install_with_retry: the watchdog leaves fast failures alone" {
	_hide_coreutils_timeout
	_mock_install_script 'exit 124'
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=5 run playwright_install_with_retry pwr install chromium
	assert_failure 124
	assert_output --partial "attempt 1 failed (exit 124); retrying once"
	assert_output --partial "::error::Playwright browser install failed twice (timeout or error)"
	refute_output --partial "timed out"
	_mock_install_script 'kill -KILL $$'
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=5 run playwright_install_with_retry pwr install chromium
	assert_failure 137
	assert_output --partial "::error::Playwright browser install failed twice (timeout or error)"
	refute_output --partial "timed out"
	_mock_install_script 'exit 0'
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=5 run playwright_install_with_retry pwr install chromium
	assert_success
	assert_output ""
}

@test "playwright_install_with_retry: without perl, job control still kills the group" {
	_hide_coreutils_timeout
	playwright_have_perl() { return 1; }
	export PIDS="${BATS_TEST_TMPDIR}/pids"
	_mock_install_script 'sleep 30 >&- 2>&- & echo "$!" >>"$PIDS"; wait'
	PLAYWRIGHT_INSTALL_TIMEOUT_SECONDS=1 run playwright_install_with_retry pwr install chromium
	assert_failure 124
	assert_output --partial \
		"::error::Playwright browser install timed out twice (1s per attempt)"
	assert_equal "$(_pwr_calls | wc -l | tr -d ' ')" "2"
	_assert_all_dead "$PIDS"
	# Job control is switched off again afterwards (outside `run`).
	_mock_install_script 'exit 0'
	playwright_install_with_retry pwr install chromium >/dev/null
	[[ $- != *m* ]]
}

@test "playwright_install_with_retry: an invalid kill grace is refused before running" {
	_mock_flaky_install
	PLAYWRIGHT_INSTALL_KILL_GRACE_SECONDS=x run playwright_install_with_retry pwr install
	assert_failure 2
	assert_equal "$(_pwr_calls)" ""
}

@test "playwright_timeout_bin: a non-coreutils timeout is ignored" {
	local bin="${BATS_TEST_TMPDIR}/fakebin"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\necho "ERROR: Invalid syntax."\nexit 1\n' >"${bin}/timeout"
	cp "${bin}/timeout" "${bin}/gtimeout"
	chmod +x "${bin}/timeout" "${bin}/gtimeout"
	PATH="${bin}:${PATH}" run playwright_timeout_bin
	assert_failure
}

@test "playwright_install_browsers: the browser download is retried once" {
	_mock_flaky_install
	MOCK_PW_FAILURES=1 RUNNER_OS=macOS run playwright_install_browsers webkit pwr
	assert_success
	assert_output --partial "attempt 1 failed (exit 3); retrying once"
	run _pwr_calls
	assert_line --index 0 "install --with-deps webkit"
	assert_line --index 1 "install --with-deps webkit"
}
