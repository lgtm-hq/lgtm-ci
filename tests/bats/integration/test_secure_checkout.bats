#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for secure-checkout action script

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/secure-checkout.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# STEP validation tests
# =============================================================================

@test "secure-checkout: fails when STEP is not set" {
	run bash -c 'unset STEP; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "STEP is required"
}

@test "secure-checkout: fails on unknown STEP" {
	run bash -c 'export STEP=invalid; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "Unknown step"
}

# =============================================================================
# STEP=repo-dir tests
# =============================================================================

@test "secure-checkout: repo-dir fails when WORKSPACE is not set" {
	run bash -c '
		export STEP=repo-dir
		unset WORKSPACE
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "WORKSPACE is required"
}

@test "secure-checkout: repo-dir outputs workspace when CHECKOUT_PATH is empty" {
	run bash -c '
		export STEP=repo-dir
		export WORKSPACE="/home/runner/work/repo/repo"
		export CHECKOUT_PATH=""
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_github_output "path" "/home/runner/work/repo/repo"
}

@test "secure-checkout: repo-dir outputs workspace when CHECKOUT_PATH is unset" {
	run bash -c '
		export STEP=repo-dir
		export WORKSPACE="/home/runner/work/repo/repo"
		unset CHECKOUT_PATH
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_github_output "path" "/home/runner/work/repo/repo"
}

@test "secure-checkout: repo-dir appends CHECKOUT_PATH to workspace" {
	run bash -c '
		export STEP=repo-dir
		export WORKSPACE="/home/runner/work/repo/repo"
		export CHECKOUT_PATH="subdir"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_github_output "path" "/home/runner/work/repo/repo/subdir"
}

# =============================================================================
# STEP=verify tests
# =============================================================================

@test "secure-checkout: verify fails when REPOSITORY is not set" {
	run bash -c '
		export STEP=verify
		unset REPOSITORY
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "REPOSITORY is required"
}

@test "secure-checkout: verify fails when not in a git repository" {
	run bash -c '
		cd "$BATS_TEST_TMPDIR"
		export STEP=verify
		export REPOSITORY="owner/repo"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "Checkout verification failed"
}

@test "secure-checkout: verify succeeds in a git repository" {
	setup_mock_git_repo

	run bash -c '
		cd "$MOCK_GIT_REPO"
		export STEP=verify
		export REPOSITORY="owner/repo"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Repository: owner/repo"
	assert_output --partial "Commit:"
}

@test "secure-checkout: verify warns when credential helper is set with persist-credentials=false" {
	setup_mock_git_repo
	(cd "$MOCK_GIT_REPO" && git config credential.helper "store")

	run bash -c '
		cd "$MOCK_GIT_REPO"
		export STEP=verify
		export REPOSITORY="owner/repo"
		export PERSIST_CREDENTIALS=false
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Credential helper is configured despite persist-credentials=false"
}

@test "secure-checkout: verify does not warn when persist-credentials=true" {
	setup_mock_git_repo
	(cd "$MOCK_GIT_REPO" && git config credential.helper "store")

	run bash -c '
		cd "$MOCK_GIT_REPO"
		export STEP=verify
		export REPOSITORY="owner/repo"
		export PERSIST_CREDENTIALS=true
		bash "$SCRIPT" 2>&1
	'
	assert_success
	refute_output --partial "Credential helper is configured"
}

@test "secure-checkout: verify does not warn when no credential helper is set" {
	setup_mock_git_repo

	run bash -c '
		cd "$MOCK_GIT_REPO"
		export GIT_CONFIG_GLOBAL=/dev/null
		export GIT_CONFIG_NOSYSTEM=1
		export STEP=verify
		export REPOSITORY="owner/repo"
		export PERSIST_CREDENTIALS=false
		bash "$SCRIPT" 2>&1
	'
	assert_success
	refute_output --partial "Credential helper is configured"
}
