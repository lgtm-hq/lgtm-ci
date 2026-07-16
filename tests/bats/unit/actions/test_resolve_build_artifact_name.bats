#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/resolve-build-artifact-name.sh (#522)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/resolve-build-artifact-name.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "resolve-build-artifact-name: keeps name in single-version mode" {
	run env \
		ARTIFACT_NAME="js-dist" \
		NODE_VERSION="20" \
		MATRIX_MODE="false" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: js-dist"
	run grep -q '^artifact-name=js-dist$' "$GITHUB_OUTPUT"
	assert_success
}

@test "resolve-build-artifact-name: suffixes version in matrix mode" {
	run env \
		ARTIFACT_NAME="js-dist" \
		NODE_VERSION="22" \
		MATRIX_MODE="true" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: js-dist-22"
	run grep -q '^artifact-name=js-dist-22$' "$GITHUB_OUTPUT"
	assert_success
}

@test "resolve-build-artifact-name: rejects empty artifact name" {
	run env \
		ARTIFACT_NAME="  " \
		NODE_VERSION="20" \
		MATRIX_MODE="false" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "ARTIFACT_NAME must not be empty"
}
