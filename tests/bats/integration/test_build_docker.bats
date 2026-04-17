#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for build-docker.sh action script (classify step)

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/build-docker.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT

	# Defaults for classify step; individual tests override as needed
	export STEP="classify"
	export PLATFORMS="linux/amd64,linux/arm64"
	export PUSH="true"
	export RUNNER_MAP='{"linux/arm64":"ubuntu-24.04-arm"}'
	unset SMOKE_TEST SMOKE_TEST_SCRIPT || true
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Require jq (classify shells out) and bash 4+ (classify uses `declare -A`).
# GitHub Actions ubuntu runners satisfy both; macOS system bash is 3.x.
setup_file() {
	if ! command -v jq >/dev/null 2>&1; then
		skip "jq not available — required by build-docker.sh classify step"
	fi
}

# Run the script with modern bash (bash 4+); skip on bash 3 hosts.
_run_script() {
	if ! bash4_available; then
		skip "requires bash 4+ (classify uses associative arrays)"
	fi
	run "$MODERN_BASH" "$SCRIPT"
}

# =============================================================================
# Smoke-test mutex validation (fail fast before any build job runs)
# =============================================================================

@test "build-docker classify: fails when smoke-test and smoke-test-script both set" {
	export SMOKE_TEST="--version"
	export SMOKE_TEST_SCRIPT="scripts/smoke.sh"

	_run_script
	assert_failure
	assert_output --partial "mutually exclusive"
}

@test "build-docker classify: succeeds with only smoke-test set" {
	export SMOKE_TEST="--version"

	_run_script
	assert_success
	assert_github_output "use-split" "true"
}

@test "build-docker classify: succeeds with only smoke-test-script set" {
	export SMOKE_TEST_SCRIPT="scripts/smoke.sh"

	_run_script
	assert_success
	assert_github_output "use-split" "true"
}

@test "build-docker classify: succeeds with neither smoke input set" {
	_run_script
	assert_success
	assert_github_output "use-split" "true"
}

# =============================================================================
# Sanity: required-input validation is unchanged by the smoke additions
# =============================================================================

@test "build-docker classify: fails when PLATFORMS is unset" {
	unset PLATFORMS
	_run_script
	assert_failure
	assert_output --partial "PLATFORMS"
}

@test "build-docker classify: fails when PUSH is unset" {
	unset PUSH
	_run_script
	assert_failure
	assert_output --partial "PUSH"
}
