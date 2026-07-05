#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/enable-auto-merge.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="scripts/ci/release/enable-auto-merge.sh"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "enable-auto-merge: fails without PR_NUMBER" {
	run env -u PR_NUMBER bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "PR_NUMBER is required"
}

@test "enable-auto-merge: enables squash auto-merge for the PR" {
	mock_command_record "gh" ""

	PR_NUMBER="42" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Auto-merge enabled for PR #42"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output --partial "pr merge 42 --auto --squash"
}

@test "enable-auto-merge: fails when gh fails" {
	mock_command_record "gh" "merge failed" 1

	PR_NUMBER="42" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
}
