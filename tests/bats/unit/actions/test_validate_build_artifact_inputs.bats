#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/validate-build-artifact-inputs.sh (#522)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-build-artifact-inputs.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "validate-build-artifact-inputs: accepts single node-version" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="20" \
		NODE_VERSION_MATRIX="" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved Node.js versions: 20"
	assert_output --partial "Matrix mode: false"
	run grep -q '^versions=20$' "$GITHUB_OUTPUT"
	assert_success
	run grep -q '^matrix-mode=false$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: accepts JSON node-version-matrix" {
	run env \
		BUILD_COMMAND="./scripts/build.sh --quick" \
		ARTIFACT_PATH="js-dist" \
		NODE_VERSION="" \
		NODE_VERSION_MATRIX='["20","22"]' \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved Node.js versions: 20,22"
	assert_output --partial "Matrix mode: true"
	run grep -q '^versions=20,22$' "$GITHUB_OUTPUT"
	assert_success
	run grep -q '^matrix-mode=true$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: rejects both node-version and node-version-matrix" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="20" \
		NODE_VERSION_MATRIX='["20","22"]' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "exactly one of node-version or node-version-matrix"
}

@test "validate-build-artifact-inputs: rejects neither node-version nor matrix" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="" \
		NODE_VERSION_MATRIX="" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "exactly one of node-version or node-version-matrix"
}

@test "validate-build-artifact-inputs: rejects empty artifact-path" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="  " \
		NODE_VERSION="20" \
		NODE_VERSION_MATRIX="" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "artifact-path is required"
}

@test "validate-build-artifact-inputs: rejects empty build-command" {
	run env \
		BUILD_COMMAND="" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="20" \
		NODE_VERSION_MATRIX="" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "build-command is required"
}

@test "validate-build-artifact-inputs: rejects invalid JSON matrix" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="" \
		NODE_VERSION_MATRIX='[20,22]' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "non-empty strings"
}

@test "validate-build-artifact-inputs: rejects empty JSON matrix array" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="" \
		NODE_VERSION_MATRIX='[]' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "non-empty JSON array"
}
