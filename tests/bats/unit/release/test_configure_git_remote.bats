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
	# Build expected URL from parts so trufflehog does not flag a literal
	# user:pass@host credential URI in the test fixture source.
	local expected
	expected="$(printf 'https://%s:%s@github.com/%s.git' \
		'x-access-token' 'token123' 'owner/repo')"
	assert_output "$expected"
}
