#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/extract-version-from-commit.sh

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

run_extract() {
	local commit_msg="$1"
	run env \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		COMMIT_MESSAGE="$commit_msg" \
		bash -c "'$PROJECT_ROOT/scripts/ci/release/extract-version-from-commit.sh' 2>&1"
}

run_extract_from_git() {
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		unset COMMIT_MESSAGE
		'$PROJECT_ROOT/scripts/ci/release/extract-version-from-commit.sh' 2>&1
	"
}

# =============================================================================
# Tests: env var override
# =============================================================================

@test "extract-version: extracts 1.2.3 from commit message" {
	run_extract "chore(release): version 1.2.3"
	assert_success
	assert_line --partial "version=1.2.3"
	assert_line --partial "found=true"
}

@test "extract-version: extracts 0.1.0 from commit message" {
	run_extract "chore(release): version 0.1.0"
	assert_success
	assert_line --partial "version=0.1.0"
	assert_line --partial "found=true"
}

@test "extract-version: extracts 10.20.30 from commit message" {
	run_extract "chore(release): version 10.20.30"
	assert_success
	assert_line --partial "version=10.20.30"
	assert_line --partial "found=true"
}

@test "extract-version: fails on feat commit" {
	run_extract "feat: add something"
	assert_failure
	assert_line --partial "found=false"
}

@test "extract-version: fails on chore(release) without version number" {
	run_extract "chore(release): bump"
	assert_failure
	assert_line --partial "found=false"
}

@test "extract-version: fails on non-semver version" {
	run_extract "chore(release): version abc"
	assert_failure
	assert_line --partial "found=false"
}

# =============================================================================
# Tests: from git
# =============================================================================

@test "extract-version: reads from git when COMMIT_MESSAGE not set" {
	setup_mock_git_repo
	add_commit "chore(release): version 3.0.0"

	run_extract_from_git
	assert_success
	assert_line --partial "version=3.0.0"
	assert_line --partial "found=true"
}
