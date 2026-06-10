#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-rust-toolchain-matrix.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "generate-rust-toolchain-matrix: uses fallback toolchain for single version" {
	run env \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		RUST_TOOLCHAIN="stable" \
		RUST_TOOLCHAINS="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-rust-toolchain-matrix.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"stable"'
}

@test "generate-rust-toolchain-matrix: expands comma-separated toolchains" {
	run env \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		RUST_TOOLCHAIN="stable" \
		RUST_TOOLCHAINS="stable,beta,1.85.0" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-rust-toolchain-matrix.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"stable"'
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"beta"'
	assert_file_contains "$GITHUB_OUTPUT" '"rust-toolchain":"1.85.0"'
}
