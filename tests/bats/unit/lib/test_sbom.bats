#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/sbom.sh (aggregator)

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# Aggregator loading tests
# =============================================================================

@test "sbom.sh: sources sbom/format.sh" {
	run bash -c 'source "$LIB_DIR/sbom.sh" && declare -f get_sbom_extension >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "sbom.sh: sources sbom/severity.sh" {
	run bash -c 'source "$LIB_DIR/sbom.sh" && declare -f severity_to_number >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "sbom.sh: sources sbom/target.sh" {
	run bash -c 'source "$LIB_DIR/sbom.sh" && declare -f resolve_scan_target >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "sbom.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/sbom.sh"
		source "$LIB_DIR/sbom.sh"
		declare -f severity_to_number >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "sbom.sh: sets _LGTM_CI_SBOM_LOADED guard" {
	run bash -c 'source "$LIB_DIR/sbom.sh" && echo "${_LGTM_CI_SBOM_LOADED}"'
	assert_success
	assert_output "1"
}
