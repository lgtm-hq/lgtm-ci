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
# Helpers
# =============================================================================

run_check() {
	local expect_version_files="${1:-true}"
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export EXPECT_VERSION_FILES='$expect_version_files'
		'$PROJECT_ROOT/scripts/ci/release/check-version-files-changed.sh' 2>&1
	"
}

read_github_output() {
	local key="$1"
	grep "^${key}=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

# =============================================================================
# Tests: EXPECT_VERSION_FILES=true (caller has ecosystems/script)
# =============================================================================

@test "expect-version-files=true: no changes → false" {
	setup_mock_git_repo
	run_check "true"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "false" ]]
}

@test "expect-version-files=true: only CHANGELOG.md changed → false (script bug)" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "## [1.0.0]" >>CHANGELOG.md
		git add CHANGELOG.md
	)
	run_check "true"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "false" ]]
	assert_line --partial "Only CHANGELOG.md changed"
}

@test "expect-version-files=true: version file changed → true" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo '{"version": "2.0.0"}' >package.json
		git add package.json
	)
	run_check "true"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "true" ]]
}

@test "expect-version-files=true: both CHANGELOG.md and version file → true" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "## [2.0.0]" >>CHANGELOG.md
		echo '{"version": "2.0.0"}' >package.json
		git add CHANGELOG.md package.json
	)
	run_check "true"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "true" ]]
}

@test "expect-version-files=true: untracked files only → false" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "temp" >untracked.txt
	)
	run_check "true"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "false" ]]
}

# =============================================================================
# Tests: EXPECT_VERSION_FILES=false (CHANGELOG-only caller like lgtm-ci)
# =============================================================================

@test "expect-version-files=false: no changes → false" {
	setup_mock_git_repo
	run_check "false"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "false" ]]
}

@test "expect-version-files=false: only CHANGELOG.md changed → true" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "## [1.0.0]" >>CHANGELOG.md
		git add CHANGELOG.md
	)
	run_check "false"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "true" ]]
}

@test "expect-version-files=false: version file changed → true" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo '{"version": "2.0.0"}' >package.json
		git add package.json
	)
	run_check "false"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "true" ]]
}

@test "expect-version-files=false: untracked files only → false" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "temp" >untracked.txt
	)
	run_check "false"
	assert_success
	[[ "$(read_github_output has-pr-changes)" == "false" ]]
}

# =============================================================================
# Tests: default behavior (unset EXPECT_VERSION_FILES)
# =============================================================================

@test "default (unset EXPECT_VERSION_FILES): behaves as expect=true" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "## [1.0.0]" >>CHANGELOG.md
		git add CHANGELOG.md
	)
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		unset EXPECT_VERSION_FILES
		'$PROJECT_ROOT/scripts/ci/release/check-version-files-changed.sh' 2>&1
	"
	assert_success
	# Default is true, so CHANGELOG-only should be rejected
	[[ "$(read_github_output has-pr-changes)" == "false" ]]
}
