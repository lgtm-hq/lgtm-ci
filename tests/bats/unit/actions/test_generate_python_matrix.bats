#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-python-matrix.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "generate-python-matrix: uses default python version" {
	run env PYTHON_VERSION=3.12 PYTHON_VERSIONS="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-python-matrix.sh"

	assert_success
	assert_output --partial "Python matrix: 3.12"
	assert_file_contains "$GITHUB_OUTPUT" 'matrix=\{"include":\[\{"python-version":"3.12"\}\]\}'
}

@test "generate-python-matrix: uses comma-separated python versions" {
	run env PYTHON_VERSION=3.12 PYTHON_VERSIONS="3.12,3.14" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-python-matrix.sh"

	assert_success
	assert_output --partial "Python matrix: 3.12, 3.14"
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.12"'
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.14"'
}

@test "generate-python-matrix: python-versions overrides singular version" {
	run env PYTHON_VERSION=3.11 PYTHON_VERSIONS="3.12,3.13" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-python-matrix.sh"

	assert_success
	refute_output --partial "3.11"
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.12"'
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.13"'
}

@test "generate-python-matrix: deduplicates python versions" {
	run env PYTHON_VERSION=3.12 PYTHON_VERSIONS="3.12,3.12,3.14,3.14" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-python-matrix.sh"

	assert_success
	assert_output --partial "Python matrix: 3.12, 3.14"
	assert_file_contains "$GITHUB_OUTPUT" 'matrix=\{"include":\[\{"python-version":"3.12"\},\{"python-version":"3.14"\}\]\}'
}

@test "generate-python-matrix: fails without GITHUB_OUTPUT" {
	run env -u GITHUB_OUTPUT PYTHON_VERSION=3.12 \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-python-matrix.sh"

	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}
