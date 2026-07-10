#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/record-digest.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/record-digest.sh"
VALID_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "record-digest.sh: fails without DIGEST" {
	run env -u DIGEST DIGEST_FILE="${BATS_TEST_TMPDIR}/d.txt" bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST is required"
}

@test "record-digest.sh: fails without DIGEST_FILE" {
	run env -u DIGEST_FILE DIGEST="$VALID_DIGEST" bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST_FILE is required"
}

@test "record-digest.sh: rejects invalid digest format" {
	run env \
		DIGEST="not-a-digest" \
		DIGEST_FILE="${BATS_TEST_TMPDIR}/nested/d.txt" \
		bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST is not a valid sha256 digest"
}

@test "record-digest.sh: writes digest and creates parent dirs" {
	local out="${BATS_TEST_TMPDIR}/nested/out/digest.txt"
	run env DIGEST="$VALID_DIGEST" DIGEST_FILE="$out" bash "$SCRIPT"
	assert_success
	assert_output --partial "Recorded digest to ${out}"
	[[ -f "$out" ]]
	run cat "$out"
	assert_output "$VALID_DIGEST"
}
