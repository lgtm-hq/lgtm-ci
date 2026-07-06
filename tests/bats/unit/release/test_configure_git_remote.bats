#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/configure-git-remote.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="scripts/ci/release/configure-git-remote.sh"

setup() {
	setup_temp_dir
	setup_mock_git_repo
	git -C "$MOCK_GIT_REPO" remote add origin "git@github.com:old/origin.git"
}

teardown() {
	teardown_temp_dir
}

@test "configure-git-remote: fails without GH_APP_TOKEN" {
	run env -u GH_APP_TOKEN GH_REPOSITORY="owner/repo" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "GH_APP_TOKEN is required"
}

@test "configure-git-remote: fails without GH_REPOSITORY" {
	run env -u GH_REPOSITORY GH_APP_TOKEN="token123" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "GH_REPOSITORY is required"
}

@test "configure-git-remote: rewrites origin URL with app token" {
	(
		cd "$MOCK_GIT_REPO" || exit 1
		GH_APP_TOKEN="token123" GH_REPOSITORY="owner/repo" \
			bash "${PROJECT_ROOT}/${SCRIPT}"
	)

	run git -C "$MOCK_GIT_REPO" remote get-url origin
	assert_success
	assert_output "https://x-access-token:token123@github.com/owner/repo.git"
}
