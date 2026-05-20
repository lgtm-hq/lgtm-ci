#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for fork PR guard in scripts/ci/actions/post-pr-comment.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GH_TOKEN="test-token"
	export GITHUB_REPOSITORY="lgtm-hq/consumer"
	export PR_NUMBER="42"
	export MARKER="test-marker"
	export MODE="upsert"
	export DELETE_ON_EMPTY="false"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "post-pr-comment: skips posting on fork pull_request" {
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="fork-user/consumer" \
		BODY_FROM_INPUT="hello" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"

	assert_success
	assert_output --partial "Skipped: fork PR"
	assert_file_exists "$GITHUB_OUTPUT"
	grep -q 'action-taken=skipped' "$GITHUB_OUTPUT"
}

@test "post-pr-comment: allows posting on same-repo pull_request" {
	# gh is not available in unit tests; expect failure after fork guard passes
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FROM_INPUT="hello" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"

	assert_failure
	refute_output --partial "Skipped: fork PR"
}
