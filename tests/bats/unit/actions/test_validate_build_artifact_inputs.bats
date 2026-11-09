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

@test "validate-build-artifact-inputs: bare node falls back to lts/* with no sources" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		WORKING_DIRECTORY="$BATS_TEST_TMPDIR" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "::notice::No node-version given; using lts/* from fallback"
	run grep -q '^versions=lts/\*$' "$GITHUB_OUTPUT"
	assert_success
}

# Run the validator against a checkout in BATS_TEST_TMPDIR with extra env.
run_default_resolution() {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		WORKING_DIRECTORY="$BATS_TEST_TMPDIR" \
		"$@" \
		bash "$SCRIPT"
}

@test "validate-build-artifact-inputs: resolves node from .nvmrc" {
	echo "v20.11.0" >"$BATS_TEST_TMPDIR/.nvmrc"
	run_default_resolution
	assert_success
	assert_output --partial "using v20.11.0 from .nvmrc"
	run grep -q '^versions=v20.11.0$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: resolves node from .node-version" {
	echo "22" >"$BATS_TEST_TMPDIR/.node-version"
	run_default_resolution
	assert_success
	assert_output --partial "using 22 from .node-version"
	run grep -q '^versions=22$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: resolves node from package.json engines" {
	echo '{"engines":{"node":">=20 <23"}}' >"$BATS_TEST_TMPDIR/package.json"
	run_default_resolution
	assert_success
	assert_output --partial "using 20 from package.json engines.node"
	run grep -q '^versions=20$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: reduces a caret engines range to its major" {
	echo '{"engines":{"node":"^22.1"}}' >"$BATS_TEST_TMPDIR/package.json"
	run_default_resolution
	assert_success
	run grep -q '^versions=22$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: reduces an OR engines range to the lowest major" {
	echo '{"engines":{"node":"22.x || 20.x"}}' >"$BATS_TEST_TMPDIR/package.json"
	run_default_resolution
	assert_success
	run grep -q '^versions=20$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: ignores package.json without engines.node" {
	echo '{"name":"x"}' >"$BATS_TEST_TMPDIR/package.json"
	run_default_resolution
	assert_success
	assert_output --partial "from fallback"
}

@test "validate-build-artifact-inputs: .nvmrc beats .node-version and engines" {
	echo "18" >"$BATS_TEST_TMPDIR/.nvmrc"
	echo "20" >"$BATS_TEST_TMPDIR/.node-version"
	echo '{"engines":{"node":">=22"}}' >"$BATS_TEST_TMPDIR/package.json"
	run_default_resolution
	assert_success
	assert_output --partial "using 18 from .nvmrc"
}

@test "validate-build-artifact-inputs: .node-version beats engines" {
	echo "20" >"$BATS_TEST_TMPDIR/.node-version"
	echo '{"engines":{"node":">=22"}}' >"$BATS_TEST_TMPDIR/package.json"
	run_default_resolution
	assert_success
	assert_output --partial "using 20 from .node-version"
}

@test "validate-build-artifact-inputs: explicit node-version beats checkout files" {
	echo "18" >"$BATS_TEST_TMPDIR/.nvmrc"
	run_default_resolution NODE_VERSION="24"
	assert_success
	refute_output --partial "::notice::"
	run grep -q '^versions=24$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: explicit toolchain-version beats checkout files" {
	echo "18" >"$BATS_TEST_TMPDIR/.nvmrc"
	run_default_resolution TOOLCHAIN_VERSION="24"
	assert_success
	refute_output --partial "::notice::"
	run grep -q '^versions=24$' "$GITHUB_OUTPUT"
	assert_success
}

@test "validate-build-artifact-inputs: matrix and node-version-matrix skip resolution" {
	echo "18" >"$BATS_TEST_TMPDIR/.nvmrc"
	run_default_resolution MATRIX='[{"node-version":"20"}]'
	assert_success
	refute_output --partial "::notice::"
	run_default_resolution NODE_VERSION_MATRIX='["20","22"]'
	assert_success
	refute_output --partial "::notice::"
}

@test "validate-build-artifact-inputs: non-node toolchains ignore checkout node files" {
	echo "18" >"$BATS_TEST_TMPDIR/.nvmrc"
	run_default_resolution TOOLCHAIN="rust"
	assert_success
	refute_output --partial "::notice::"
	run grep -q '^versions=stable$' "$GITHUB_OUTPUT"
	assert_success
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

@test "validate-build-artifact-inputs: matrix keeps toolchain-version as the leg default" {
	run env \
		BUILD_COMMAND="bun run build" \
		ARTIFACT_PATH="dist" \
		TOOLCHAIN_VERSION="22" \
		MATRIX='[{"target":"linux"},{"target":"darwin"}]' \
		bash "$SCRIPT"

	assert_success
	run grep -q '^toolchain-version=22$' "$GITHUB_OUTPUT"
	assert_success
	run grep -q '^matrix-mode=true$' "$GITHUB_OUTPUT"
	assert_success
}
