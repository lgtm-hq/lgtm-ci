#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/sign-image.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/sign-image.sh"
VALID_DIGEST="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export DIGEST="$VALID_DIGEST"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

@test "sign-image.sh: signs image digest with cosign" {
	mock_command_record "cosign"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Signed image: ghcr.io/org/repo@${VALID_DIGEST}"
	run grep -Fx "sign --yes ghcr.io/org/repo@${VALID_DIGEST}" "${BATS_TEST_TMPDIR}/mock_calls_cosign"
	assert_success
}

@test "sign-image.sh: rejects invalid digest" {
	export DIGEST="not-a-digest"
	mock_command_record "cosign"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST is not a valid sha256 digest"
}

@test "sign-image.sh: fails when cosign is missing" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	export PATH="${mock_bin}:/usr/bin:/bin"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "cosign not found"
}

@test "sign-image.sh: requires DIGEST" {
	unset DIGEST || true
	mock_command_record "cosign"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST is required"
}
