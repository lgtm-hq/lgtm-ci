#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/notify/context.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export LIB_DIR
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_context() {
	run bash -c 'source "$LIB_DIR/notify/context.sh" && "$@"' _ "$@"
}

@test "notify_validate_status: accepts success, failure, cancelled" {
	for status in success failure cancelled; do
		run_context notify_validate_status "$status"
		assert_success
	done
}

@test "notify_validate_status: rejects unknown status" {
	run_context notify_validate_status "bogus"
	assert_failure
	assert_output --partial "invalid status 'bogus'"
}

@test "notify_status_color: maps statuses to hex colors" {
	run_context notify_status_color "success"
	assert_success
	assert_output "#2da44e"

	run_context notify_status_color "failure"
	assert_output "#cf222e"

	run_context notify_status_color "cancelled"
	assert_output "#d4a72c"
}

@test "notify_status_color_decimal: converts hex to decimal" {
	run_context notify_status_color_decimal "success"
	assert_success
	assert_output "2991182"
}

@test "notify_run_url: builds run URL from environment" {
	run_context notify_run_url
	assert_success
	assert_output "https://github.com/test-org/test-repo/actions/runs/12345"
}

@test "notify_run_url: fails without GITHUB_RUN_ID" {
	unset GITHUB_RUN_ID
	run_context notify_run_url
	assert_failure
	assert_output --partial "GITHUB_REPOSITORY and GITHUB_RUN_ID are required"
}

@test "notify_context_json: injects repo, run_url, ref, actor" {
	run_context notify_context_json
	assert_success

	run jq -r '.repo, .run_url, .ref, .actor' <<<"$output"
	assert_line --index 0 "test-org/test-repo"
	assert_line --index 1 "https://github.com/test-org/test-repo/actions/runs/12345"
	assert_line --index 2 "main"
	assert_line --index 3 "test-user"
}
