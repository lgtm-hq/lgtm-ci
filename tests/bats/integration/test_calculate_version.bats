#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/calculate-version.sh

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

# Run calculate-version.sh in the mock git repo
# Usage: run_calculate_version [MAX_BUMP]
run_calculate_version() {
	local max_bump="${1:-major}"
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export MAX_BUMP='$max_bump'
		export FROM_REF=
		export TO_REF=HEAD
		'$PROJECT_ROOT/scripts/ci/release/calculate-version.sh' 2>&1
	"
}

# =============================================================================
# Floating tag tests
# =============================================================================

@test "calculate-version: skips floating tag and uses semver tag" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: initial feature"
		git tag "v0.1.0"
		# Simulate floating tag created by update-floating-tag.sh
		git tag -fa "v0" "v0.1.0" -m "Release v0 (latest: v0.1.0)"
		git commit -q --allow-empty -m "feat: new feature"
	)

	run_calculate_version "minor"
	assert_success
	assert_line --partial "current-version=0.1.0"
	assert_line --partial "next-version=0.2.0"
	assert_line --partial "bump-type=minor"
	assert_line --partial "release-needed=true"
}

@test "calculate-version: handles multiple floating tags" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: first"
		git tag "v0.1.0"
		git tag -fa "v0" "v0.1.0" -m "Release v0 (latest: v0.1.0)"

		git commit -q --allow-empty -m "feat: second"
		git tag "v1.0.0"
		git tag -fa "v1" "v1.0.0" -m "Release v1 (latest: v1.0.0)"

		git commit -q --allow-empty -m "fix: bugfix"
	)

	run_calculate_version "major"
	assert_success
	assert_line --partial "current-version=1.0.0"
	assert_line --partial "next-version=1.0.1"
	assert_line --partial "bump-type=patch"
}

@test "calculate-version: works with no tags at all" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: first feature"
	)

	run_calculate_version "minor"
	assert_success
	assert_line --partial "current-version=0.0.0"
	assert_line --partial "next-version=0.1.0"
	assert_line --partial "bump-type=minor"
	assert_line --partial "release-needed=true"
}

@test "calculate-version: works with only semver tags (no floating)" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: initial"
		git tag "v1.0.0"
		git commit -q --allow-empty -m "feat: new feature"
	)

	run_calculate_version "minor"
	assert_success
	assert_line --partial "current-version=1.0.0"
	assert_line --partial "next-version=1.1.0"
}
