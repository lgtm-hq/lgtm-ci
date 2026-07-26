#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-build-matrix.sh (#760)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/generate-build-matrix.sh"
LEGACY_SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/generate-version-matrix.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

emitted_matrix() {
	grep '^matrix=' "$GITHUB_OUTPUT" | sed 's/^matrix=//'
}

# The legacy Node path must stay byte-identical to the matrix that
# generate-version-matrix.sh produced before #760, so existing callers keep
# their job names and required-check contexts.
legacy_matrix() {
	local versions="$1"
	local legacy_output="${BATS_TEST_TMPDIR}/legacy_output"
	: >"$legacy_output"
	GITHUB_OUTPUT="$legacy_output" \
		MATRIX_KEY="node-version" \
		MATRIX_LABEL="Node.js" \
		DEFAULT_VERSION="$versions" \
		VERSIONS_INPUT="$versions" \
		bash "$LEGACY_SCRIPT" >/dev/null
	grep '^matrix=' "$legacy_output" | sed 's/^matrix=//'
}

@test "generate-build-matrix: single legacy version matches generate-version-matrix" {
	run env \
		VERSION_KEY="node-version" \
		VERSIONS="20" \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" '{"include":[{"node-version":"20"}]}'
	assert_equal "$(emitted_matrix)" "$(legacy_matrix 20)"
}

@test "generate-build-matrix: legacy version list matches generate-version-matrix" {
	run env \
		VERSION_KEY="node-version" \
		VERSIONS="20,22" \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" '{"include":[{"node-version":"20"},{"node-version":"22"}]}'
	assert_equal "$(emitted_matrix)" "$(legacy_matrix 20,22)"
}

@test "generate-build-matrix: legacy path injects no runner field" {
	run env \
		VERSION_KEY="node-version" \
		VERSIONS="20,22" \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	refute_output --partial "runner"
	run grep -c "runner" "$GITHUB_OUTPUT"
	assert_failure
}

@test "generate-build-matrix: deduplicates repeated legacy versions" {
	run env \
		VERSION_KEY="node-version" \
		VERSIONS="20,22,20" \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" '{"include":[{"node-version":"20"},{"node-version":"22"}]}'
}

@test "generate-build-matrix: accepts an arbitrary JSON array matrix" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"x86_64-apple-darwin"},{"target":"x86_64-unknown-linux-musl"}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"target":"x86_64-apple-darwin"},{"target":"x86_64-unknown-linux-musl"}]}'
}

@test "generate-build-matrix: accepts an object matrix with include" {
	run env \
		VERSION_KEY="" \
		MATRIX='{"include":[{"target":"wasm32-wasip1"}]}' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" '{"include":[{"target":"wasm32-wasip1"}]}'
}

@test "generate-build-matrix: injects the toolchain version into matrix entries" {
	run env \
		VERSION_KEY="rust-toolchain" \
		TOOLCHAIN_VERSION="stable" \
		MATRIX='[{"target":"x86_64-apple-darwin"}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"target":"x86_64-apple-darwin","rust-toolchain":"stable"}]}'
}

@test "generate-build-matrix: keeps a per-entry toolchain version" {
	run env \
		VERSION_KEY="python-version" \
		TOOLCHAIN_VERSION="3.12" \
		MATRIX='[{"python-version":"3.11"},{"python-version":"3.13"}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"python-version":"3.11"},{"python-version":"3.13"}]}'
}

@test "generate-build-matrix: rejects matrix entries with no resolvable version" {
	run env \
		VERSION_KEY="node-version" \
		TOOLCHAIN_VERSION="" \
		MATRIX='[{"target":"linux"}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "matrix entries must set 'node-version'"
}

@test "generate-build-matrix: routes matrix entries through runner-map" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"x86_64-apple-darwin"},{"target":"x86_64-pc-windows-msvc"}]' \
		RUNNER_MAP='{"x86_64-apple-darwin":"macos-15","x86_64-pc-windows-msvc":"windows-2025"}' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"target":"x86_64-apple-darwin","runner":"macos-15"},{"target":"x86_64-pc-windows-msvc","runner":"windows-2025"}]}'
}

@test "generate-build-matrix: unmapped entry falls back to the default runner" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"x86_64-apple-darwin"},{"target":"x86_64-unknown-linux-musl"}]' \
		RUNNER_MAP='{"x86_64-apple-darwin":"macos-15"}' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "::notice::No runner-map entry for target=x86_64-unknown-linux-musl"
	assert_output --partial "using default runner ubuntu-24.04"
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"target":"x86_64-apple-darwin","runner":"macos-15"},{"target":"x86_64-unknown-linux-musl","runner":"ubuntu-24.04"}]}'
}

@test "generate-build-matrix: runner-map keys off the legacy node-version field" {
	run env \
		VERSION_KEY="node-version" \
		VERSIONS="20,22" \
		RUNNER_MAP='{"22":"ubuntu-24.04-arm"}' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"node-version":"20","runner":"ubuntu-24.04"},{"node-version":"22","runner":"ubuntu-24.04-arm"}]}'
}

@test "generate-build-matrix: requires runner-map-key for multi-field entries" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"x86_64-apple-darwin","archive":"tar.gz"}]' \
		RUNNER_MAP='{"x86_64-apple-darwin":"macos-15"}' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "runner-map needs runner-map-key"
}

@test "generate-build-matrix: honours an explicit runner-map-key" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"x86_64-apple-darwin","archive":"tar.gz"}]' \
		RUNNER_MAP='{"x86_64-apple-darwin":"macos-15"}' \
		RUNNER_MAP_KEY="target" \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"target":"x86_64-apple-darwin","archive":"tar.gz","runner":"macos-15"}]}'
}

@test "generate-build-matrix: rejects an entry without the runner-map-key field" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"x86_64-apple-darwin","archive":"tar.gz"},{"archive":"zip"}]' \
		RUNNER_MAP='{"x86_64-apple-darwin":"macos-15"}' \
		RUNNER_MAP_KEY="target" \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "matrix entry #2 has no 'target' field"
}

@test "generate-build-matrix: toolchain none without a matrix yields one runner leg" {
	run env \
		VERSION_KEY="" \
		VERSIONS="" \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" '{"include":[{"runner":"ubuntu-24.04"}]}'
}

@test "generate-build-matrix: normalises non-string scalar matrix values" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"aarch64-unknown-linux-gnu","cross":true}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"target":"aarch64-unknown-linux-gnu","cross":"true"}]}'
}

@test "generate-build-matrix: rejects nested matrix values" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":{"triple":"x86_64"}}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "must be a scalar"
}

@test "generate-build-matrix: rejects invalid matrix JSON" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{target}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "matrix must be valid JSON"
}

@test "generate-build-matrix: rejects an empty matrix array" {
	run env \
		VERSION_KEY="" \
		MATRIX='[]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "non-empty JSON array of objects"
}

@test "generate-build-matrix: rejects an invalid runner-map" {
	run env \
		VERSION_KEY="node-version" \
		VERSIONS="20" \
		RUNNER_MAP='["macos-15"]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "runner-map must be a JSON object"
}

@test "generate-build-matrix: requires DEFAULT_RUNNER" {
	run env \
		VERSION_KEY="node-version" \
		VERSIONS="20" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "DEFAULT_RUNNER"
}

@test "generate-build-matrix: deduplicates identical matrix legs" {
	run env \
		VERSION_KEY="" \
		MATRIX='[{"target":"linux"},{"target":"linux"}]' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" '{"include":[{"target":"linux"}]}'
}

@test "generate-build-matrix: injected version keeps runner-map auto-detection" {
	run env \
		VERSION_KEY="rust-toolchain" \
		TOOLCHAIN_VERSION="stable" \
		MATRIX='[{"target":"aarch64-apple-darwin"},{"target":"x86_64-unknown-linux-musl"}]' \
		RUNNER_MAP='{"aarch64-apple-darwin":"macos-15"}' \
		DEFAULT_RUNNER="ubuntu-24.04" \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(emitted_matrix)" \
		'{"include":[{"target":"aarch64-apple-darwin","rust-toolchain":"stable","runner":"macos-15"},{"target":"x86_64-unknown-linux-musl","rust-toolchain":"stable","runner":"ubuntu-24.04"}]}'
}
