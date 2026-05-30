#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for record-pages-coverage-upload-status.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_github_env
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/record-pages-coverage-upload-status.sh"
}

@test "record-pages-coverage-upload-status: reports false when upload disabled" {
	UPLOAD_PAGES_COVERAGE_HTML=false COVERAGE=true run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=false$' "$GITHUB_OUTPUT"
	assert_success
}

@test "record-pages-coverage-upload-status: reports true after successful main push" {
	UPLOAD_PAGES_COVERAGE_HTML=true COVERAGE=true \
		TEST_COMMAND="" TEST_VITEST_RESULT=success TEST_CUSTOM_RESULT=skipped \
		GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
		run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=true$' "$GITHUB_OUTPUT"
	assert_success
}

@test "record-pages-coverage-upload-status: reports false on pull requests" {
	UPLOAD_PAGES_COVERAGE_HTML=true COVERAGE=true \
		TEST_COMMAND="" TEST_VITEST_RESULT=success TEST_CUSTOM_RESULT=skipped \
		GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
		run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=false$' "$GITHUB_OUTPUT"
	assert_success
}

@test "record-pages-coverage-upload-status: uses custom test job result" {
	UPLOAD_PAGES_COVERAGE_HTML=true COVERAGE=true \
		TEST_COMMAND="bun run test:coverage" TEST_VITEST_RESULT=skipped \
		TEST_CUSTOM_RESULT=success GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
		run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=true$' "$GITHUB_OUTPUT"
	assert_success
}
