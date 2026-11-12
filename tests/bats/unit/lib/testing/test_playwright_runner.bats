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
