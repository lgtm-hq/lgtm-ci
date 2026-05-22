#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for build-docker.sh action script

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

# Run the script with any bash (steps that don't need bash 4+ features).
_run_script_any_bash() {
	run bash "$SCRIPT"
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

@test "build-docker classify: disables split when push is false and validate-on-pr is false" {
	export PUSH="false"

	_run_script
	assert_success
	assert_github_output "use-split" "false"
	assert_github_output "matrix" "[]"
}

@test "build-docker classify: enables split when push is false and validate-on-pr is true" {
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

@test "build-docker classify: validate-on-pr with single mapped platform enables split" {
	export PLATFORMS="linux/arm64"
	export PUSH="false"
	export VALIDATE_ON_PR="true"

	_run_script
	assert_success
	assert_github_output "use-split" "true"

	local matrix
	matrix=$(get_github_output "matrix")
	[[ "$matrix" == *"linux/arm64"* ]]
	[[ "$(echo "$matrix" | jq 'length')" -eq 1 ]]
	[[ "$(echo "$matrix" | jq -r '.[0].platform')" == "linux/arm64" ]]
	[[ "$(echo "$matrix" | jq -r '.[0].runner')" == "ubuntu-24.04-arm" ]]
}

@test "build-docker summary: writes digest and cosign verify command" {
	export STEP="summary"
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="lgtm-hq/example"
	export PLATFORMS="linux/amd64,linux/arm64"
	export PUSH="true"
	export DIGEST="sha256:abc123"
	export COSIGN_SIGNED="true"
	export SCAN_ENABLED="true"
	export GITHUB_REPOSITORY="lgtm-hq/example"

	_run_script_any_bash
	assert_success

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"sha256:abc123"* ]]
	[[ "$summary" == *"cosign verify"* ]]
	[[ "$summary" == *"https://github.com/lgtm-hq/example/.*"* ]]
	[[ "$summary" == *"Vulnerability scan"* ]]
}

@test "build-docker summary: includes per-platform matrix when provided" {
	export STEP="summary"
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="lgtm-hq/example"
	export PLATFORMS="linux/amd64,linux/arm64"
	export VALIDATE_ON_PR="true"
	export MATRIX='[{"platform":"linux/amd64","runner":"ubuntu-24.04","slug":"linux-amd64","qemu":false},{"platform":"linux/arm64","runner":"ubuntu-24.04-arm","slug":"linux-arm64","qemu":false}]'

	_run_script_any_bash
	assert_success

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"linux/amd64"* ]]
	[[ "$summary" == *"linux/arm64"* ]]
	[[ "$summary" == *"PR validation"* ]]
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

# =============================================================================
# record-digest step
# =============================================================================

@test "build-docker record-digest: writes valid digest to file" {
	export STEP="record-digest"
	export DIGEST="sha256:$(printf '%0.s0' {1..64})"
	export DIGEST_FILE="${BATS_TEST_TMPDIR}/staging-digest/digest.txt"

	_run_script_any_bash
	assert_success

	assert_file_exists "$DIGEST_FILE"
	run cat "$DIGEST_FILE"
	assert_output "$DIGEST"
}

@test "build-docker record-digest: creates parent directory" {
	export STEP="record-digest"
	export DIGEST="sha256:$(printf '%0.s0' {1..64})"
	export DIGEST_FILE="${BATS_TEST_TMPDIR}/nested/dir/digest.txt"

	_run_script_any_bash
	assert_success
	assert_file_exists "$DIGEST_FILE"
}

@test "build-docker record-digest: rejects invalid digest" {
	export STEP="record-digest"
	export DIGEST="not-a-digest"
	export DIGEST_FILE="${BATS_TEST_TMPDIR}/digest.txt"

	_run_script_any_bash
	assert_failure
	assert_output --partial "not a valid sha256 digest"
}

@test "build-docker record-digest: fails when DIGEST is unset" {
	export STEP="record-digest"
	unset DIGEST
	export DIGEST_FILE="${BATS_TEST_TMPDIR}/digest.txt"

	_run_script_any_bash
	assert_failure
	assert_output --partial "DIGEST"
}

@test "build-docker record-digest: fails when DIGEST_FILE is unset" {
	export STEP="record-digest"
	export DIGEST="sha256:$(printf '%0.s0' {1..64})"
	unset DIGEST_FILE

	_run_script_any_bash
	assert_failure
	assert_output --partial "DIGEST_FILE"
}

# =============================================================================
# parse-tags step
# =============================================================================

@test "build-docker parse-tags: converts comma-separated tags to metadata-action format" {
	export STEP="parse-tags"
	export INPUT_TAGS="latest,stable"

	_run_script_any_bash
	assert_success

	local tags
	tags=$(get_github_output "tags")
	[[ "$tags" == *"type=raw,value=latest"* ]]
	[[ "$tags" == *"type=raw,value=stable"* ]]
}

@test "build-docker parse-tags: handles single tag" {
	export STEP="parse-tags"
	export INPUT_TAGS="nightly"

	_run_script_any_bash
	assert_success

	local tags
	tags=$(get_github_output "tags")
	[[ "$tags" == *"type=raw,value=nightly"* ]]
}

@test "build-docker parse-tags: outputs empty when INPUT_TAGS is empty" {
	export STEP="parse-tags"
	export INPUT_TAGS=""

	_run_script_any_bash
	assert_success

	# set_github_output writes "tags=" (empty value); verify the key exists
	run grep "^tags=" "$GITHUB_OUTPUT"
	assert_success
}

# =============================================================================
# set-output-digest step
# =============================================================================

@test "build-docker set-output-digest: writes digest to GITHUB_OUTPUT" {
	export STEP="set-output-digest"
	export DIGEST="sha256:abc123"

	_run_script_any_bash
	assert_success
	assert_github_output "digest" "sha256:abc123"
}

@test "build-docker set-output-digest: fails when DIGEST is unset" {
	export STEP="set-output-digest"
	unset DIGEST

	_run_script_any_bash
	assert_failure
	assert_output --partial "DIGEST"
}
