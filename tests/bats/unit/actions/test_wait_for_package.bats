#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/wait-for-package.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/wait-for-package.sh"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_wait_for_package() {
	run bash "${PROJECT_ROOT}/${SCRIPT}"
}

@test "wait-for-package: fails without STEP" {
	run env -u STEP REGISTRY="npm" PACKAGE="pkg" VERSION="1.0.0" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "wait-for-package: fails without REGISTRY" {
	run env -u REGISTRY STEP="check" PACKAGE="pkg" VERSION="1.0.0" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "REGISTRY is required"
}

@test "wait-for-package: check reports npm package available" {
	mock_curl "200"

	STEP="check" REGISTRY="npm" PACKAGE="pkg" VERSION="1.0.0" run_wait_for_package
	assert_success
	assert_output --partial "pkg@1.0.0 is available on npm"
	assert_file_contains "$GITHUB_OUTPUT" "available=true"
}

@test "wait-for-package: check reports npm package not yet available" {
	mock_curl "404"

	STEP="check" REGISTRY="npm" PACKAGE="pkg" VERSION="1.0.0" run_wait_for_package
	assert_success
	assert_output --partial "not yet available"
	assert_file_contains "$GITHUB_OUTPUT" "available=false"
}

@test "wait-for-package: check reports pypi package available" {
	mock_curl "200"

	STEP="check" REGISTRY="pypi" PACKAGE="pkg" VERSION="1.0.0" run_wait_for_package
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "available=true"
}

@test "wait-for-package: check reports gem availability from versions API" {
	mock_curl '[{"number": "1.0.0"}]'

	STEP="check" REGISTRY="gem" PACKAGE="pkg" VERSION="1.0.0" run_wait_for_package
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "available=true"
}

@test "wait-for-package: check fails on unknown registry" {
	STEP="check" REGISTRY="cargo" PACKAGE="pkg" VERSION="1.0.0" run_wait_for_package
	assert_failure
	assert_output --partial "Unknown registry"
}

@test "wait-for-package: wait succeeds when package is available" {
	mock_curl "200"

	STEP="wait" REGISTRY="npm" PACKAGE="pkg" VERSION="1.0.0" run_wait_for_package
	assert_success
	assert_output --partial "is now available"
	assert_file_contains "$GITHUB_OUTPUT" "available=true"
	assert_file_contains "$GITHUB_OUTPUT" "elapsed="
}

@test "wait-for-package: wait times out when package never appears" {
	mock_curl "404"
	mock_command "sleep" ""

	STEP="wait" REGISTRY="npm" PACKAGE="pkg" VERSION="1.0.0" MAX_WAIT="1" \
		run_wait_for_package
	assert_failure
	assert_output --partial "Timeout waiting for pkg@1.0.0"
	assert_file_contains "$GITHUB_OUTPUT" "available=false"
}

@test "wait-for-package: summary reports availability" {
	STEP="summary" REGISTRY="npm" PACKAGE="pkg" VERSION="1.0.0" \
		AVAILABLE="true" ELAPSED="12" run_wait_for_package
	assert_success

	run get_github_step_summary
	assert_output --partial "Package Availability"
	assert_output --partial "12s"
	assert_output --partial "Available"
}

@test "wait-for-package: fails on unknown step" {
	STEP="bogus" REGISTRY="npm" PACKAGE="pkg" VERSION="1.0.0" run_wait_for_package
	assert_failure
	assert_output --partial "Unknown step"
}
