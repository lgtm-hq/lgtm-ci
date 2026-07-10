#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/set-output-digest.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/set-output-digest.sh"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "set-output-digest.sh: fails without DIGEST" {
	run env -u DIGEST bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST is required"
}

@test "set-output-digest.sh: writes digest to GITHUB_OUTPUT" {
	local digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	run env DIGEST="$digest" bash "$SCRIPT"
	assert_success
	assert_output --partial "Digest: ${digest}"
	assert_github_output "digest" "$digest"
}
