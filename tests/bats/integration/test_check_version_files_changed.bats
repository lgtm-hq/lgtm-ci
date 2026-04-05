#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/check-version-files-changed.sh

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

run_check() {
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		'$PROJECT_ROOT/scripts/ci/release/check-version-files-changed.sh' 2>&1
	"
}

# Read a value from the GITHUB_OUTPUT file
read_github_output() {
	local key="$1"
	grep "^${key}=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

# =============================================================================
# Tests
# =============================================================================

@test "check-version-files-changed: no changes → false" {
	setup_mock_git_repo

	run_check
	assert_success

	RESULT=$(read_github_output "has-version-changes")
	[[ "$RESULT" == "false" ]]
}

@test "check-version-files-changed: only CHANGELOG.md changed → false" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "## [1.0.0]" >>CHANGELOG.md
		git add CHANGELOG.md
	)

	run_check
	assert_success

	RESULT=$(read_github_output "has-version-changes")
	[[ "$RESULT" == "false" ]]
}

@test "check-version-files-changed: version file changed → true" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo '{"version": "2.0.0"}' >package.json
		git add package.json
	)

	run_check
	assert_success

	RESULT=$(read_github_output "has-version-changes")
	[[ "$RESULT" == "true" ]]
}

@test "check-version-files-changed: both CHANGELOG.md and version file → true" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "## [2.0.0]" >>CHANGELOG.md
		echo '{"version": "2.0.0"}' >package.json
		git add CHANGELOG.md package.json
	)

	run_check
	assert_success

	RESULT=$(read_github_output "has-version-changes")
	[[ "$RESULT" == "true" ]]
}

@test "check-version-files-changed: untracked files only → false" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "temp" >untracked.txt
	)

	run_check
	assert_success

	RESULT=$(read_github_output "has-version-changes")
	[[ "$RESULT" == "false" ]]
}
