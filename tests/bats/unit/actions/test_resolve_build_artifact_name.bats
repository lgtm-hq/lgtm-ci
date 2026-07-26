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

# --- toolchain-agnostic matrix suffixes (#760) ------------------------------

@test "resolve-build-artifact-name: MATRIX_JSON reproduces the legacy node suffix" {
	run env \
		ARTIFACT_NAME="js-dist" \
		MATRIX_JSON='{"node-version":"22"}' \
		MATRIX_MODE="true" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: js-dist-22"
}

@test "resolve-build-artifact-name: MATRIX_JSON keeps single-version names verbatim" {
	run env \
		ARTIFACT_NAME="js-dist" \
		MATRIX_JSON='{"node-version":"22"}' \
		MATRIX_MODE="false" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: js-dist"
}

@test "resolve-build-artifact-name: suffixes an arbitrary matrix target" {
	run env \
		ARTIFACT_NAME="rustume" \
		MATRIX_JSON='{"target":"x86_64-apple-darwin","rust-toolchain":"stable"}' \
		MATRIX_MODE="true" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: rustume-x86_64-apple-darwin-stable"
}

@test "resolve-build-artifact-name: excludes the runner-map runner from the suffix" {
	run env \
		ARTIFACT_NAME="rustume" \
		MATRIX_JSON='{"target":"x86_64-apple-darwin","runner":"macos-15"}' \
		MATRIX_MODE="true" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: rustume-x86_64-apple-darwin"
	refute_output --partial "macos-15"
}

@test "resolve-build-artifact-name: sanitises characters illegal in artifact names" {
	run env \
		ARTIFACT_NAME="dist" \
		MATRIX_JSON='{"platform":"linux/arm64"}' \
		MATRIX_MODE="true" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: dist-linux-arm64"
}

@test "resolve-build-artifact-name: falls back to NODE_VERSION when MATRIX_JSON is empty" {
	run env \
		ARTIFACT_NAME="js-dist" \
		MATRIX_JSON="" \
		NODE_VERSION="20" \
		MATRIX_MODE="true" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved artifact name: js-dist-20"
}

@test "resolve-build-artifact-name: rejects matrix mode with no suffix source" {
	run env \
		ARTIFACT_NAME="js-dist" \
		MATRIX_JSON='{"runner":"ubuntu-24.04"}' \
		MATRIX_MODE="true" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "MATRIX_JSON or NODE_VERSION"
}
