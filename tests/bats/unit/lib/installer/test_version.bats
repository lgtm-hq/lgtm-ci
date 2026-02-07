#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/installer/version.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# installer_check_version tests
# =============================================================================

@test "installer_check_version: returns 0 when correct version installed" {
	mock_command "mytool" "mytool version 1.2.3"

	run bash -c 'source "$LIB_DIR/installer/version.sh" && installer_check_version "mytool" "1.2.3" 2>&1'
	assert_success
	assert_output --partial "already installed"
}

@test "installer_check_version: returns 1 when wrong version installed" {
	mock_command "mytool" "mytool version 1.0.0"

	run bash -c 'source "$LIB_DIR/installer/version.sh" && installer_check_version "mytool" "2.0.0" 2>&1'
	assert_failure
	assert_output --partial "Found mytool 1.0.0, need 2.0.0"
}

@test "installer_check_version: returns 1 when tool not installed" {
	run bash -c 'source "$LIB_DIR/installer/version.sh" && installer_check_version "nonexistent-tool-xyz" "1.0.0" 2>&1'
	assert_failure
}

@test "installer_check_version: uses custom version_cmd" {
	mock_command "mytool" "v3.5.0"

	run bash -c 'source "$LIB_DIR/installer/version.sh" && installer_check_version "mytool" "3.5.0" "version" 2>&1'
	assert_success
	assert_output --partial "already installed"
}

@test "installer_check_version: extracts version from verbose output" {
	mock_command "mytool" "mytool - A great tool v2.1.0 (built 2024-01-01)"

	run bash -c 'source "$LIB_DIR/installer/version.sh" && installer_check_version "mytool" "2.1.0" 2>&1'
	assert_success
	assert_output --partial "already installed"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "version.sh: exports installer_check_version function" {
	run bash -c 'source "$LIB_DIR/installer/version.sh" && declare -f installer_check_version >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "version.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/installer/version.sh"
		source "$LIB_DIR/installer/version.sh"
		declare -f installer_check_version >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "version.sh: sets _LGTM_CI_INSTALLER_VERSION_LOADED guard" {
	run bash -c 'source "$LIB_DIR/installer/version.sh" && echo "${_LGTM_CI_INSTALLER_VERSION_LOADED}"'
	assert_success
	assert_output "1"
}
