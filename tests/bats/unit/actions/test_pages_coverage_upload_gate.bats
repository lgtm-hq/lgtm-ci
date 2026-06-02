#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for pages-coverage-upload-gate.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_github_env
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/pages-coverage-upload-gate.sh"
}

teardown() {
	teardown_github_env
}

@test "pages-coverage-upload-gate: push-main allows push to main" {
	GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main PAGES_COVERAGE_UPLOAD_ON=push-main \
		run bash "$SCRIPT"
	assert_success
	grep -q '^should-upload=true$' "$GITHUB_OUTPUT"
}

@test "pages-coverage-upload-gate: push-main blocks pull requests" {
	GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge PAGES_COVERAGE_UPLOAD_ON=push-main \
		run bash "$SCRIPT"
	assert_success
	grep -q '^should-upload=false$' "$GITHUB_OUTPUT"
}

@test "pages-coverage-upload-gate: push-main blocks push to non-main branches" {
	GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/feature PAGES_COVERAGE_UPLOAD_ON=push-main \
		run bash "$SCRIPT"
	assert_success
	grep -q '^should-upload=false$' "$GITHUB_OUTPUT"
}

@test "pages-coverage-upload-gate: rejects unknown upload-on values" {
	GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main PAGES_COVERAGE_UPLOAD_ON=always \
		run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Unsupported pages-coverage-upload-on"
}
