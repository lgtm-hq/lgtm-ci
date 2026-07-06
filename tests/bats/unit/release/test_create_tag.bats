#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/create-tag.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	setup_mock_git_repo
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_create_tag() {
	(
		cd "$MOCK_GIT_REPO" || exit 1
		bash "${PROJECT_ROOT}/scripts/ci/release/create-tag.sh"
	)
}

@test "create-tag: fails without VERSION" {
	run env -u VERSION bash "${PROJECT_ROOT}/scripts/ci/release/create-tag.sh"
	assert_failure
	assert_output --partial "VERSION is required"
}

@test "create-tag: creates annotated tag with v prefix" {
	add_commit "feat: add feature"

	VERSION="1.2.3" run run_create_tag
	assert_success
	assert_output --partial "tag-name=v1.2.3"

	run git -C "$MOCK_GIT_REPO" cat-file -t refs/tags/v1.2.3
	assert_success
	assert_output "tag"
}

@test "create-tag: strips existing v prefix from VERSION" {
	VERSION="v2.0.0" run run_create_tag
	assert_success
	assert_output --partial "tag-name=v2.0.0"
	git -C "$MOCK_GIT_REPO" rev-parse --verify refs/tags/v2.0.0
}

@test "create-tag: honors custom TAG_PREFIX" {
	VERSION="1.0.0" TAG_PREFIX="release-" run run_create_tag
	assert_success
	assert_output --partial "tag-name=release-1.0.0"
	git -C "$MOCK_GIT_REPO" rev-parse --verify refs/tags/release-1.0.0
}

@test "create-tag: fails when tag already exists" {
	git -C "$MOCK_GIT_REPO" tag -a v1.2.3 -m "existing"

	VERSION="1.2.3" run run_create_tag
	assert_failure
	assert_output --partial "already exists"
}

@test "create-tag: uses custom MESSAGE for tag annotation" {
	VERSION="1.2.3" MESSAGE="custom tag message" run run_create_tag
	assert_success

	run git -C "$MOCK_GIT_REPO" tag -l --format='%(contents:subject)' v1.2.3
	assert_success
	assert_output "custom tag message"
}

@test "create-tag: writes GitHub Actions outputs" {
	VERSION="1.2.3" run run_create_tag
	assert_success

	assert_file_contains "$GITHUB_OUTPUT" "tag-name=v1.2.3"
	assert_file_contains "$GITHUB_OUTPUT" "version=1.2.3"
	assert_file_contains "$GITHUB_OUTPUT" "tag-sha="
	assert_file_contains "$GITHUB_OUTPUT" "commit-sha="
}

@test "create-tag: tag sha and commit sha match repo state" {
	VERSION="1.2.3" run run_create_tag
	assert_success

	local head_sha
	head_sha=$(git -C "$MOCK_GIT_REPO" rev-parse HEAD)
	assert_output --partial "commit-sha=${head_sha}"
}
