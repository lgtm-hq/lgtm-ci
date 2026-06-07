#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/check-version-unchanged.sh

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

run_check() {
	local current="$1"
	local previous="${2:-}"
	run bash -c "
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export CURRENT_VERSION='$current'
		export PREVIOUS_VERSION='$previous'
		'$PROJECT_ROOT/scripts/ci/release/check-version-unchanged.sh' 2>&1
	"
}

@test "check-version-unchanged: tags when no previous version exists" {
	run_check "1.0.0"
	assert_success
	assert_line --partial "should-tag=true"
	assert_line --partial "unchanged=false"
}

@test "check-version-unchanged: skips when versions match" {
	run_check "1.0.0" "1.0.0"
	assert_success
	assert_line --partial "should-tag=false"
	assert_line --partial "unchanged=true"
}

@test "check-version-unchanged: tags when versions differ" {
	run_check "1.1.0" "1.0.0"
	assert_success
	assert_line --partial "should-tag=true"
	assert_line --partial "unchanged=false"
}
