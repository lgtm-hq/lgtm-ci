#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for record-pages-upload-outcome.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_github_env
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/record-pages-upload-outcome.sh"
}

teardown() {
	teardown_github_env
}

@test "record-pages-upload-outcome: writes upload step outcome" {
	PAGES_UPLOAD_OUTCOME=success run bash "$SCRIPT"
	assert_success
	run grep -q '^outcome=success$' "$GITHUB_OUTPUT"
	assert_success
}

@test "record-pages-upload-outcome: writes empty outcome when unset" {
	run bash "$SCRIPT"
	assert_success
	run grep -q '^outcome=$' "$GITHUB_OUTPUT"
	assert_success
}
