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
