#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/guard-release-commit.sh

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# Helper
# =============================================================================

run_guard() {
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		'$PROJECT_ROOT/scripts/ci/release/guard-release-commit.sh' 2>&1
	"
}

# =============================================================================
# Tests
# =============================================================================

@test "guard-release-commit: detects chore(release): version as release commit" {
	setup_mock_git_repo
	add_commit "chore(release): version 1.2.3"

	run_guard
	assert_success
	assert_line --partial "is-release-commit=true"
}

@test "guard-release-commit: detects chore(release): prepare as release commit" {
	setup_mock_git_repo
	add_commit "chore(release): prepare 0.3.0"

	run_guard
	assert_success
	assert_line --partial "is-release-commit=true"
}

@test "guard-release-commit: feat commit is not a release commit" {
	setup_mock_git_repo
	add_commit "feat: add new feature"

	run_guard
	assert_success
	assert_line --partial "is-release-commit=false"
}

@test "guard-release-commit: fix commit is not a release commit" {
	setup_mock_git_repo
	add_commit "fix: resolve bug"

	run_guard
	assert_success
	assert_line --partial "is-release-commit=false"
}

@test "guard-release-commit: chore without release scope is not a release commit" {
	setup_mock_git_repo
	add_commit "chore: update dependencies"

	run_guard
	assert_success
	assert_line --partial "is-release-commit=false"
}

@test "guard-release-commit: always exits 0 regardless of result" {
	setup_mock_git_repo
	add_commit "feat: something"

	run_guard
	assert_success

	add_commit "chore(release): version 2.0.0"
	run_guard
	assert_success
}
