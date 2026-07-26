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

# --- toolchain-agnostic inputs (#760) ---------------------------------------

@test "validate-build-artifact-inputs: legacy node call emits node toolchain outputs" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="20" \
		bash "$SCRIPT"

	assert_success
	run grep -q '^toolchain=node$' "$GITHUB_OUTPUT"
	assert_success
	run grep -q '^version-key=node-version$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: rejects an unknown toolchain" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN="deno" \
		TOOLCHAIN_VERSION="2" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "toolchain must be one of: node, rust, python, none"
}

@test "validate-build-artifact-inputs: rust toolchain defaults to stable" {
	run env \
		BUILD_COMMAND="cargo build --release" \
		ARTIFACT_PATH="target/release/app" \
		TOOLCHAIN="rust" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved Rust versions: stable"
	run grep -q '^version-key=rust-toolchain$' "$GITHUB_OUTPUT"
	assert_success
	run grep -q '^versions=stable$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: python toolchain honours toolchain-version" {
	run env \
		BUILD_COMMAND="uv build" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN="python" \
		TOOLCHAIN_VERSION="3.13" \
		bash "$SCRIPT"

	assert_success
	run grep -q '^version-key=python-version$' "$GITHUB_OUTPUT"
	assert_success
	run grep -q '^versions=3.13$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: python toolchain defaults to 3.12" {
	run env \
		BUILD_COMMAND="uv build" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN="python" \
		bash "$SCRIPT"

	assert_success
	run grep -q '^versions=3.12$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: toolchain none needs no version" {
	run env \
		BUILD_COMMAND="make dist" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN="none" \
		bash "$SCRIPT"

	assert_success
	run grep -q '^version-key=$' "$GITHUB_OUTPUT"
	assert_success
	run grep -q '^matrix-mode=false$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: toolchain-version is a node-version alias" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN_VERSION="22" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Resolved Node.js versions: 22"
	run grep -q '^versions=22$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: rejects node-version with a non-node toolchain" {
	run env \
		BUILD_COMMAND="cargo build" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN="rust" \
		NODE_VERSION="20" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "require toolchain: node"
}

@test "validate-build-artifact-inputs: rejects node-version with toolchain-version" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="20" \
		TOOLCHAIN_VERSION="22" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "Set node-version or toolchain-version, not both"
}

@test "validate-build-artifact-inputs: matrix sets matrix mode" {
	run env \
		BUILD_COMMAND="cargo build --release" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN="rust" \
		MATRIX='[{"target":"x86_64-apple-darwin"}]' \
		bash "$SCRIPT"

	assert_success
	run grep -q '^matrix-mode=true$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: rejects matrix with node-version" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION="20" \
		MATRIX='[{"node-version":"20"}]' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "matrix is mutually exclusive"
}

@test "validate-build-artifact-inputs: rejects matrix with node-version-matrix" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION_MATRIX='["20"]' \
		MATRIX='[{"node-version":"20"}]' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "matrix is mutually exclusive"
}

@test "validate-build-artifact-inputs: warns that node-version-matrix is deprecated" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		NODE_VERSION_MATRIX='["20","22"]' \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "::warning::node-version-matrix is deprecated"
}
