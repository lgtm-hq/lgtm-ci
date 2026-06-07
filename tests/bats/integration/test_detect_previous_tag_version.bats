#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/detect-previous-tag-version.sh

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

run_detect() {
	local tag_prefix="${1:-v}"
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export TAG_PREFIX='$tag_prefix'
		'$PROJECT_ROOT/scripts/ci/release/detect-previous-tag-version.sh' 2>&1
	"
}

@test "detect-previous-tag-version: extracts version from latest tag" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git tag "v1.2.3"
	)

	run_detect
	assert_success
	assert_line --partial "version=1.2.3"
	assert_line --partial "found=true"
}

@test "detect-previous-tag-version: reports not found when no tags exist" {
	setup_mock_git_repo

	run_detect
	assert_success
	assert_line --partial "found=false"
}

@test "detect-previous-tag-version: strips custom tag prefix" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git tag "release-2.0.0"
	)

	run_detect "release-"
	assert_success
	assert_line --partial "version=2.0.0"
	assert_line --partial "found=true"
}

@test "detect-previous-tag-version: selects highest semver, not git describe order" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git tag "v1.0.0"
		git tag "v1.2.0"
		git tag "v1.2.1"
	)

	run_detect
	assert_success
	assert_line --partial "version=1.2.1"
	assert_line --partial "found=true"
}
