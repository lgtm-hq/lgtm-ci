#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/publish.sh (aggregator)

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# Aggregator loading tests
# =============================================================================

@test "publish.sh: sources publish/version.sh" {
	run bash -c 'source "$LIB_DIR/publish.sh" && declare -f extract_pypi_version >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "publish.sh: sources publish/validate.sh" {
	run bash -c 'source "$LIB_DIR/publish.sh" && declare -f validate_pypi_package >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "publish.sh: sources publish/registry.sh" {
	run bash -c 'source "$LIB_DIR/publish.sh" && declare -f check_pypi_availability >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "publish.sh: sources publish/homebrew.sh" {
	run bash -c 'source "$LIB_DIR/publish.sh" && declare -f generate_formula_from_pypi >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "publish.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/publish.sh"
		source "$LIB_DIR/publish.sh"
		declare -f extract_pypi_version >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "publish.sh: sets _LGTM_CI_PUBLISH_LOADED guard" {
	run bash -c 'source "$LIB_DIR/publish.sh" && echo "${_LGTM_CI_PUBLISH_LOADED}"'
	assert_success
	assert_output "1"
}
