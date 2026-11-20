#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/build-lychee-args.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/build-lychee-args.sh"

setup() {
	setup_temp_dir
	setup_github_env
	cd "$BATS_TEST_TMPDIR" || return 1
	unset PATHS FILE_EXTENSIONS EXCLUDE_PATTERNS CHECK_EXTERNAL TIMEOUT WORKING_DIRECTORY
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "build-lychee-args: writes the default arguments as one args output" {
	run bash "$SCRIPT"

	assert_success
	run github_file_keys "$GITHUB_OUTPUT"
	assert_output "args"
	run get_github_output "args"
	assert_output "--no-progress --format markdown --timeout 10 --max-retries 3 --accept 200..=204 '**/*.md' '**/*.html'"
}

@test "build-lychee-args: offline mode and exclusions are quoted into args" {
	run env CHECK_EXTERNAL=false EXCLUDE_PATTERNS="https://a.example, it's" bash "$SCRIPT"

	assert_success
	run get_github_output "args"
	assert_output --partial "--offline"
	assert_output --partial "--exclude 'https://a.example' --exclude 'it'\\''s'"
}

@test "build-lychee-args: a delimiter in caller input sets no extra output (#1675)" {
	run env TIMEOUT=$'10\nLYCHEE_ARGS\ninjected=true\nEOF' bash "$SCRIPT"

	assert_success
	run github_file_keys "$GITHUB_OUTPUT"
	assert_output "args"
	run grep -c '^args<<ghadelimiter_[0-9a-f]\{32\}$' "$GITHUB_OUTPUT"
	assert_output "1"
	run get_github_output "args"
	assert_output --partial $'--timeout 10\nLYCHEE_ARGS\ninjected=true\nEOF --max-retries'
}

@test "build-lychee-args: requires GITHUB_OUTPUT" {
	run env -u GITHUB_OUTPUT bash "$SCRIPT"

	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}
