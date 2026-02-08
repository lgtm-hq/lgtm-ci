#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/check-existing-version-pr.sh

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

run_check_pr() {
	run bash -c "
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export GH_TOKEN='fake-token'
		export PATH='$PATH'
		'$PROJECT_ROOT/scripts/ci/release/check-existing-version-pr.sh' 2>&1
	"
}

# =============================================================================
# Tests
# =============================================================================

@test "check-existing-version-pr: returns false when no PRs match" {
	mock_command "gh" ""
	mock_command "jq" ""

	run_check_pr
	assert_success
	assert_line --partial "pr-exists=false"
}

@test "check-existing-version-pr: returns true when a PR matches" {
	mock_command "gh" '{"number":42,"title":"chore(release): version 1.0.0","url":"https://github.com/test/repo/pull/42"}'

	run_check_pr
	assert_success
	assert_line --partial "pr-exists=true"
	assert_line --partial "pr-number=42"
}

@test "check-existing-version-pr: handles gh CLI failure gracefully" {
	mock_command "gh" "" 1

	run_check_pr
	assert_success
	assert_line --partial "pr-exists=false"
}

@test "check-existing-version-pr: handles null response" {
	mock_command "gh" "null"

	run_check_pr
	assert_success
	assert_line --partial "pr-exists=false"
}
