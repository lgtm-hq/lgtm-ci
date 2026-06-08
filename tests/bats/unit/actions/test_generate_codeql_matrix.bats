#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-codeql-matrix.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	touch "$GITHUB_OUTPUT"
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/generate-codeql-matrix.sh"
}

teardown() {
	teardown_temp_dir
}

@test "generate-codeql-matrix: single language uses default build-mode" {
	run env LANGUAGES=python BUILD_MODE=none LANGUAGE_BUILD_MODES="" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "CodeQL matrix: python:none"
	assert_file_contains "$GITHUB_OUTPUT" \
		'matrix=\{"include":\[\{"language":"python","build-mode":"none"\}\]\}'
}

@test "generate-codeql-matrix: comma-separated languages share default build-mode" {
	run env LANGUAGES="java, kotlin" BUILD_MODE=autobuild LANGUAGE_BUILD_MODES="" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "java:autobuild, kotlin:autobuild"
	assert_file_contains "$GITHUB_OUTPUT" '"language":"java","build-mode":"autobuild"'
	assert_file_contains "$GITHUB_OUTPUT" '"language":"kotlin","build-mode":"autobuild"'
}

@test "generate-codeql-matrix: language-build-modes overrides per language" {
	run env \
		LANGUAGES="rust,actions" \
		BUILD_MODE=none \
		LANGUAGE_BUILD_MODES='{"rust":"autobuild","actions":"none"}' \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "rust:autobuild, actions:none"
	assert_file_contains "$GITHUB_OUTPUT" '"language":"rust","build-mode":"autobuild"'
	assert_file_contains "$GITHUB_OUTPUT" '"language":"actions","build-mode":"none"'
}

@test "generate-codeql-matrix: partial language-build-modes falls back to default" {
	run env \
		LANGUAGES="rust,actions" \
		BUILD_MODE=none \
		LANGUAGE_BUILD_MODES='{"rust":"autobuild"}' \
		bash "$SCRIPT"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '"language":"rust","build-mode":"autobuild"'
	assert_file_contains "$GITHUB_OUTPUT" '"language":"actions","build-mode":"none"'
}

@test "generate-codeql-matrix: empty languages emits auto-detect leg" {
	run env LANGUAGES="" BUILD_MODE=none LANGUAGE_BUILD_MODES="" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "CodeQL matrix: auto-detect:none"
	assert_file_contains "$GITHUB_OUTPUT" \
		'matrix=\{"include":\[\{"language":"","build-mode":"none"\}\]\}'
}

@test "generate-codeql-matrix: deduplicates languages" {
	run env LANGUAGES="python,python,go" BUILD_MODE=none LANGUAGE_BUILD_MODES="" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "CodeQL matrix: python:none, go:none"
	assert_file_contains "$GITHUB_OUTPUT" \
		'matrix=\{"include":\[\{"language":"python","build-mode":"none"\},\{"language":"go","build-mode":"none"\}\]\}'
}

@test "generate-codeql-matrix: fails without GITHUB_OUTPUT" {
	run env -u GITHUB_OUTPUT LANGUAGES=python \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}

@test "generate-codeql-matrix: rejects invalid language-build-modes JSON" {
	run env \
		LANGUAGES=rust \
		BUILD_MODE=none \
		LANGUAGE_BUILD_MODES='not-json' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "LANGUAGE_BUILD_MODES must be valid JSON"
}

@test "generate-codeql-matrix: rejects invalid build-mode" {
	run env \
		LANGUAGES=python \
		BUILD_MODE=invalid \
		LANGUAGE_BUILD_MODES="" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "Invalid build-mode"
}
