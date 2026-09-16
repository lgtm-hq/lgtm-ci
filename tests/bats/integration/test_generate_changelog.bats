#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/generate-changelog.sh

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

# Run generate-changelog.sh in the mock git repo with FROM_REF unset
# Usage: run_generate_changelog [VERSION]
run_generate_changelog() {
	local version="${1:-}"
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export FROM_REF=
		export TO_REF=HEAD
		export VERSION='$version'
		export FORMAT=simple
		'$PROJECT_ROOT/scripts/ci/release/generate-changelog.sh' 2>&1
	"
}

# =============================================================================
# Default FROM_REF
# =============================================================================

@test "generate-changelog: ranges from the latest stable tag, not a nearer checkpoint prerelease" {
	# calculate-version.sh already bumps from the stable tag (#1000); the
	# changelog must cover the same range, or the version PR summarises only
	# the commits since the last checkpoint and drops the rest (#1012).
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: shipped in the last stable"
		git tag "v0.1.0"
		git commit -q --allow-empty -m "feat: before the checkpoint"
		git commit -q --allow-empty -m "ci(release): checkpoint prerelease 0.1.1a4"
		git tag "v0.1.1a4"
		git tag "v0.1.1rc1"
		git commit -q --allow-empty -m "fix: after the checkpoint"
	)

	run_generate_changelog "0.2.0"
	assert_success
	assert_line --partial "from 'v0.1.0' to 'HEAD'"
	assert_output --partial "before the checkpoint"
	assert_output --partial "after the checkpoint"
	refute_output --partial "shipped in the last stable"
}

@test "generate-changelog: with no stable tag the range starts at the beginning" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: only ever a checkpoint"
		git tag "v0.1.0rc1"
	)

	run_generate_changelog
	assert_success
	assert_line --partial "from 'beginning' to 'HEAD'"
	assert_output --partial "only ever a checkpoint"
}

@test "generate-changelog: an explicit FROM_REF is used as given" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: old"
		git tag "v0.1.0"
		git commit -q --allow-empty -m "feat: newer"
		git tag "v0.2.0"
		git commit -q --allow-empty -m "fix: newest"
	)

	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export FROM_REF=v0.1.0
		export FORMAT=simple
		'$PROJECT_ROOT/scripts/ci/release/generate-changelog.sh' 2>&1
	"
	assert_success
	assert_line --partial "from 'v0.1.0' to 'HEAD'"
	assert_output --partial "newer"
	assert_output --partial "newest"
}
