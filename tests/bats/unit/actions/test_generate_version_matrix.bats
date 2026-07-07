#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-version-matrix.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "generate-version-matrix: uses default python version" {
	run env MATRIX_KEY=python-version MATRIX_LABEL=Python \
		DEFAULT_VERSION=3.12 VERSIONS_INPUT="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	assert_output --partial "Python matrix: 3.12"
	assert_file_contains "$GITHUB_OUTPUT" 'matrix=\{"include":\[\{"python-version":"3.12"\}\]\}'
}

@test "generate-version-matrix: uses comma-separated python versions" {
	run env MATRIX_KEY=python-version MATRIX_LABEL=Python \
		DEFAULT_VERSION=3.12 VERSIONS_INPUT="3.12,3.14" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	assert_output --partial "Python matrix: 3.12, 3.14"
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.12"'
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.14"'
}

@test "generate-version-matrix: versions input overrides default version" {
	run env MATRIX_KEY=python-version MATRIX_LABEL=Python \
		DEFAULT_VERSION=3.11 VERSIONS_INPUT="3.12,3.13" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	refute_output --partial "3.11"
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.12"'
	assert_file_contains "$GITHUB_OUTPUT" '"python-version":"3.13"'
}

@test "generate-version-matrix: deduplicates versions" {
	run env MATRIX_KEY=python-version MATRIX_LABEL=Python \
		DEFAULT_VERSION=3.12 VERSIONS_INPUT="3.12,3.12,3.14,3.14" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	assert_output --partial "Python matrix: 3.12, 3.14"
	assert_file_contains "$GITHUB_OUTPUT" 'matrix=\{"include":\[\{"python-version":"3.12"\},\{"python-version":"3.14"\}\]\}'
}

@test "generate-version-matrix: emits first-version output for first matrix leg" {
	run env MATRIX_KEY=node-version MATRIX_LABEL=Node.js \
		DEFAULT_VERSION=20 VERSIONS_INPUT="20,22" \
		FIRST_VERSION_OUTPUT=pages-coverage-node-version \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	assert_output --partial "First matrix version (pages-coverage-node-version): 20"
	run grep -q '^pages-coverage-node-version=20$' "$GITHUB_OUTPUT"
	assert_success
}

@test "generate-version-matrix: first-version output uses sole version when matrix is disabled" {
	run env MATRIX_KEY=node-version MATRIX_LABEL=Node.js \
		DEFAULT_VERSION=22 VERSIONS_INPUT="" \
		FIRST_VERSION_OUTPUT=pages-coverage-node-version \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	assert_output --partial "First matrix version (pages-coverage-node-version): 22"
	run grep -q '^pages-coverage-node-version=22$' "$GITHUB_OUTPUT"
	assert_success
}

@test "generate-version-matrix: omits first-version output when not requested" {
	run env MATRIX_KEY=python-version MATRIX_LABEL=Python \
		DEFAULT_VERSION=3.12 VERSIONS_INPUT="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	run grep -q 'pages-coverage' "$GITHUB_OUTPUT"
	assert_failure
}

@test "generate-version-matrix: uses fallback rust toolchain for single version" {
	run env MATRIX_KEY=rust-toolchain MATRIX_LABEL="Rust toolchain" \
		DEFAULT_VERSION=stable VERSIONS_INPUT="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	assert_output --partial "Rust toolchain matrix: stable"
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"stable"'
}

@test "generate-version-matrix: expands comma-separated rust toolchains" {
	run env MATRIX_KEY=rust-toolchain MATRIX_LABEL="Rust toolchain" \
		DEFAULT_VERSION=stable VERSIONS_INPUT="stable,beta,1.85.0" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"stable"'
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"beta"'
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"1.85.0"'
}

@test "generate-version-matrix: fails without GITHUB_OUTPUT" {
	run env -u GITHUB_OUTPUT MATRIX_KEY=python-version DEFAULT_VERSION=3.12 \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}

@test "generate-version-matrix: requires MATRIX_KEY" {
	run env -u MATRIX_KEY DEFAULT_VERSION=3.12 \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_failure
	assert_output --partial "MATRIX_KEY is required"
}

@test "generate-version-matrix: requires DEFAULT_VERSION" {
	run env -u DEFAULT_VERSION MATRIX_KEY=python-version \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

	assert_failure
	assert_output --partial "DEFAULT_VERSION is required"
}
