#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/get-pr-author.sh (#1624)

load "../../../helpers/common"
load "../../../helpers/github_env"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/get-pr-author.sh"

setup() {
	setup_github_env
}

teardown() {
	teardown_github_env
}

@test "get-pr-author.sh: writes the author login gh reports" {
	mock_command_record gh "release-bot[bot]"

	run env PR_NUMBER=42 bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output "author=release-bot[bot]"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output "pr view 42 --json author --jq .author.login"
}

@test "get-pr-author.sh: fails when gh fails, writing nothing" {
	mock_command gh "" 1

	run env PR_NUMBER=42 bash "$SCRIPT"
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output ""
}

@test "get-pr-author.sh: fails without PR_NUMBER" {
	run env -u PR_NUMBER bash "$SCRIPT"
	assert_failure
	assert_output --partial "PR_NUMBER is required"
}
