#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/installer.sh (aggregator)

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

@test "installer.sh: sources installer/core.sh" {
	run bash -c 'source "$LIB_DIR/installer.sh" && declare -f installer_init >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "installer.sh: sources installer/args.sh" {
	run bash -c 'source "$LIB_DIR/installer.sh" && declare -f installer_parse_args >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "installer.sh: sources installer/version.sh" {
	run bash -c 'source "$LIB_DIR/installer.sh" && declare -f installer_check_version >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "installer.sh: sources installer/fallbacks.sh" {
	run bash -c 'source "$LIB_DIR/installer.sh" && declare -f installer_fallback_go >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "installer.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/installer.sh"
		source "$LIB_DIR/installer.sh"
		declare -f installer_check_version >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "installer.sh: sets _LGTM_CI_INSTALLER_LOADED guard" {
	run bash -c 'source "$LIB_DIR/installer.sh" && echo "${_LGTM_CI_INSTALLER_LOADED}"'
	assert_success
	assert_output "1"
}
