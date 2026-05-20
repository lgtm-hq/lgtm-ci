#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/skip-fork-pr-comment.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_REPOSITORY="lgtm-hq/consumer"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "skip-fork-pr-comment: non-PR event outputs can-comment=false" {
	run env \
		EVENT_NAME="push" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/skip-fork-pr-comment.sh"

	assert_success
	grep -q 'can-comment=false' "$GITHUB_OUTPUT"
}

@test "skip-fork-pr-comment: fork PR outputs can-comment=false" {
	run env \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="fork-user/consumer" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/skip-fork-pr-comment.sh"

	assert_success
	grep -q 'can-comment=false' "$GITHUB_OUTPUT"
}

@test "skip-fork-pr-comment: same-repo PR outputs can-comment=true" {
	run env \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/skip-fork-pr-comment.sh"

	assert_success
	grep -q 'can-comment=true' "$GITHUB_OUTPUT"
}

@test "skip-fork-pr-comment: missing head repo on PR event is error" {
	run env \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/skip-fork-pr-comment.sh"

	assert_failure
}
