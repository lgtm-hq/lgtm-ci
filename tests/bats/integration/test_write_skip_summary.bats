#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/write-skip-summary.sh

load "../../helpers/common"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export PROJECT_ROOT
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_skip_summary() {
	local tag_exists="${1:-false}"
	local version_unchanged="${2:-false}"
	local version_found="${3:-true}"
	local is_release="${4:-true}"
	run bash -c "
		export GITHUB_STEP_SUMMARY='$GITHUB_STEP_SUMMARY'
		export TAG_EXISTS='$tag_exists'
		export VERSION_UNCHANGED='$version_unchanged'
		export VERSION_FOUND='$version_found'
		export IS_RELEASE='$is_release'
		'$PROJECT_ROOT/scripts/ci/release/write-skip-summary.sh' 2>&1
	"
}

@test "write-skip-summary: reports tag already exists" {
	run_skip_summary "true" "false" "true" "true"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: tag already exists"
}

@test "write-skip-summary: reports version unchanged" {
	run_skip_summary "false" "true" "true" "true"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: version unchanged since last tag"
}

@test "write-skip-summary: reports non-release commit when version not found" {
	run_skip_summary "false" "false" "false" "false"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: last commit is not a release commit"
}

@test "write-skip-summary: reports version not found on release commit" {
	run_skip_summary "false" "false" "false" "true"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: version not found"
}

@test "write-skip-summary: reports unexpected skip state" {
	run_skip_summary "false" "false" "true" "true"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: unexpected auto-tag skip state"
}

@test "write-skip-summary: tag already exists takes precedence over version unchanged" {
	run_skip_summary "true" "true" "true" "true"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: tag already exists"
}
