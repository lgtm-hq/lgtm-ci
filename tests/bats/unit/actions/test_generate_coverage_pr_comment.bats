#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-coverage-pr-comment.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/generate-coverage-pr-comment.sh"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "generate-coverage-pr-comment: passes with threshold in body" {
	run env \
		COVERAGE_PERCENT="92.5" \
		THRESHOLD="80" \
		COMMENT_TITLE="Coverage Report" \
		PASSED="true" \
		bash "$SCRIPT"

	assert_success
	grep -q 'comment-body<<' "$GITHUB_OUTPUT"
	grep -q '✅ \*\*Coverage: 92.5%\*\*' "$GITHUB_OUTPUT"
	grep -q '(threshold: 80%)' "$GITHUB_OUTPUT"
}

@test "generate-coverage-pr-comment: fails status omits threshold when zero" {
	run env \
		COVERAGE_PERCENT="70" \
		THRESHOLD="0" \
		COMMENT_TITLE="Custom Coverage" \
		PASSED="false" \
		bash "$SCRIPT"

	assert_success
	grep -q '## Custom Coverage' "$GITHUB_OUTPUT"
	grep -q '❌ \*\*Coverage: 70%\*\*' "$GITHUB_OUTPUT"
	run grep -q 'threshold:' "$GITHUB_OUTPUT"
	assert_failure
}

@test "generate-coverage-pr-comment: writes multiline output to GITHUB_OUTPUT" {
	run env \
		COVERAGE_PERCENT="100" \
		THRESHOLD="0" \
		PASSED="true" \
		bash "$SCRIPT"

	assert_success
	grep -q 'comment-body<<' "$GITHUB_OUTPUT"
	grep -q '✅ \*\*Coverage: 100%\*\*' "$GITHUB_OUTPUT"
}
