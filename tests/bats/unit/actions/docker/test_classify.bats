#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/classify.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/classify.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT

	# Defaults; individual tests override as needed
	export PLATFORMS="linux/amd64,linux/arm64"
	export PUSH="true"
	export RUNNER_MAP='{"linux/arm64":"ubuntu-24.04-arm"}'
	unset SMOKE_TEST SMOKE_TEST_SCRIPT HEALTH_CHECK_CMD HEALTH_CHECK_PORT HEALTH_CHECK_TIMEOUT || true
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Require jq (classify shells out) and bash 4+ (classify uses `declare -A`).
setup_file() {
	if ! command -v jq >/dev/null 2>&1; then
		skip "jq not available — required by classify.sh"
	fi
}

# Run the script with modern bash (bash 4+); skip on bash 3 hosts.
_run_script() {
	if ! bash4_available; then
		skip "requires bash 4+ (classify uses associative arrays)"
	fi
	run "$MODERN_BASH" "$SCRIPT"
}

@test "classify: fails when smoke-test and smoke-test-script both set" {
	export SMOKE_TEST="--version"
	export SMOKE_TEST_SCRIPT="scripts/smoke.sh"

	_run_script
	assert_failure
	assert_output --partial "mutually exclusive"
}

@test "classify: succeeds with only smoke-test set" {
	export SMOKE_TEST="--version"

	_run_script
	assert_success
	assert_github_output "use-split" "true"
}

@test "classify: fails when health-check-port is not numeric" {
	export HEALTH_CHECK_CMD="curl -f http://127.0.0.1:8080/health"
	export HEALTH_CHECK_PORT="not-a-port"

	_run_script
	assert_failure
	assert_output --partial "health-check-port must be a positive integer (1-65535)"
}

@test "classify: fails when health-check-cmd is set without port" {
	export HEALTH_CHECK_CMD="curl -f http://127.0.0.1:8080/health"

	_run_script
	assert_failure
	assert_output --partial "health-check-port is required"
}

@test "classify: fails when health-check-timeout is invalid" {
	export HEALTH_CHECK_CMD="curl -f http://127.0.0.1:8080/health"
	export HEALTH_CHECK_PORT="8080"
	export HEALTH_CHECK_TIMEOUT="30x"

	_run_script
	assert_failure
	assert_output --partial "Invalid HEALTH_CHECK_TIMEOUT"
}

@test "classify: fails when RUNNER_MAP is invalid JSON" {
	export RUNNER_MAP='{not json'

	_run_script
	assert_failure
	assert_output --partial "RUNNER_MAP is not valid JSON"
}

@test "classify: fails when PLATFORMS is whitespace only" {
	export PLATFORMS=" , "

	_run_script
	assert_failure
	assert_output --partial "PLATFORMS is empty"
}

@test "classify: disables split when push is false and validate-on-pr is false" {
	export PUSH="false"

	_run_script
	assert_success
	assert_github_output "use-split" "false"
	assert_github_output "matrix" "[]"
}

@test "classify: enables split when push is false and validate-on-pr is true" {
	export PUSH="false"
	export VALIDATE_ON_PR="true"

	_run_script
	assert_success
	assert_github_output "use-split" "true"

	local matrix
	matrix=$(get_github_output "matrix")
	[[ "$matrix" == *"linux/amd64"* ]]
	[[ "$matrix" == *"linux/arm64"* ]]
}

@test "classify: single mapped platform enables split with native runner" {
	export PLATFORMS="linux/arm64"
	export PUSH="false"
	export VALIDATE_ON_PR="true"

	_run_script
	assert_success
	assert_github_output "use-split" "true"

	local matrix
	matrix=$(get_github_output "matrix")
	[[ "$(echo "$matrix" | jq 'length')" -eq 1 ]]
	[[ "$(echo "$matrix" | jq -r '.[0].platform')" == "linux/arm64" ]]
	[[ "$(echo "$matrix" | jq -r '.[0].runner')" == "ubuntu-24.04-arm" ]]
	[[ "$(echo "$matrix" | jq -r '.[0].slug')" == "linux-arm64" ]]
	[[ "$(echo "$matrix" | jq -r '.[0].qemu')" == "false" ]]
}

@test "classify: single unmapped platform disables split" {
	export PLATFORMS="linux/amd64"
	export RUNNER_MAP="{}"

	_run_script
	assert_success
	assert_github_output "use-split" "false"
	assert_github_output "matrix" "[]"
}

@test "classify: deduplicates repeated platforms" {
	export PLATFORMS="linux/amd64,linux/amd64,linux/arm64"

	_run_script
	assert_success

	local matrix
	matrix=$(get_github_output "matrix")
	[[ "$(echo "$matrix" | jq 'length')" -eq 2 ]]
}

@test "classify: fails when PLATFORMS is unset" {
	unset PLATFORMS
	_run_script
	assert_failure
	assert_output --partial "PLATFORMS"
}

@test "classify: fails when PUSH is unset" {
	unset PUSH
	_run_script
	assert_failure
	assert_output --partial "PUSH"
}
