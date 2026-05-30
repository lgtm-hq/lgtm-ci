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

@test "record-pages-coverage-upload-status: reports true when upload step succeeded" {
	UPLOAD_PAGES_COVERAGE_HTML=true COVERAGE=true PAGES_UPLOAD_OUTCOME=success \
		run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=true$' "$GITHUB_OUTPUT"
	assert_success
}

@test "record-pages-coverage-upload-status: reports false when upload step failed" {
	UPLOAD_PAGES_COVERAGE_HTML=true COVERAGE=true PAGES_UPLOAD_OUTCOME=failure \
		run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=false$' "$GITHUB_OUTPUT"
	assert_success
}

@test "record-pages-coverage-upload-status: reports false when upload step skipped" {
	UPLOAD_PAGES_COVERAGE_HTML=true COVERAGE=true PAGES_UPLOAD_OUTCOME=skipped \
		run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=false$' "$GITHUB_OUTPUT"
	assert_success
}

@test "record-pages-coverage-upload-status: reports false when upload outcome missing" {
	UPLOAD_PAGES_COVERAGE_HTML=true COVERAGE=true PAGES_UPLOAD_OUTCOME="" \
		run bash "$SCRIPT"
	assert_success
	run grep -q '^uploaded=false$' "$GITHUB_OUTPUT"
	assert_success
}
