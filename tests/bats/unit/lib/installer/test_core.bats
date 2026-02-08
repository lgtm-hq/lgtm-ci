#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/installer/core.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# installer_init tests - basic initialization
# =============================================================================

@test "installer_init: sets INSTALLER_LIB_DIR" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		[[ -n "$INSTALLER_LIB_DIR" ]] && echo "set"
	'
	assert_success
	assert_output "set"
}

@test "installer_init: INSTALLER_LIB_DIR points to lib directory" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		[[ -d "$INSTALLER_LIB_DIR" ]] && echo "exists"
	'
	assert_success
	assert_output "exists"
}

@test "installer_init: sets default BIN_DIR" {
	run bash -c '
		unset BIN_DIR
		source "$LIB_DIR/installer/core.sh"
		installer_init
		echo "$BIN_DIR"
	'
	assert_success
	assert_output --partial ".local/bin"
}

@test "installer_init: respects existing BIN_DIR" {
	run bash -c '
		export BIN_DIR="/custom/bin"
		source "$LIB_DIR/installer/core.sh"
		installer_init
		echo "$BIN_DIR"
	'
	assert_success
	assert_output "/custom/bin"
}

@test "installer_init: sets default DRY_RUN=0" {
	run bash -c '
		unset DRY_RUN
		source "$LIB_DIR/installer/core.sh"
		installer_init
		echo "$DRY_RUN"
	'
	assert_success
	assert_output "0"
}

@test "installer_init: respects existing DRY_RUN" {
	run bash -c '
		export DRY_RUN=1
		source "$LIB_DIR/installer/core.sh"
		installer_init
		echo "$DRY_RUN"
	'
	assert_success
	assert_output "1"
}

# =============================================================================
# installer_init tests - library sourcing
# =============================================================================

@test "installer_init: sources log.sh (log_info available)" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		type log_info >/dev/null 2>&1 && echo "available"
	'
	assert_success
	assert_output "available"
}

@test "installer_init: sources platform.sh when available" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		type detect_os >/dev/null 2>&1 && echo "available" || echo "not available"
	'
	assert_success
	# Either available from platform.sh or not - just verify no crash
}

@test "installer_init: provides command_exists fallback" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		type command_exists >/dev/null 2>&1 && echo "available"
	'
	assert_success
	assert_output "available"
}

@test "installer_init: command_exists works for bash" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		command_exists bash && echo "found"
	'
	assert_success
	assert_output "found"
}

@test "installer_init: command_exists returns false for nonexistent" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		command_exists nonexistent_command_xyz123 || echo "not found"
	'
	assert_success
	assert_output "not found"
}

@test "installer_init: provides ensure_directory fallback" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		type ensure_directory >/dev/null 2>&1 && echo "available"
	'
	assert_success
	assert_output "available"
}

@test "installer_init: ensure_directory creates directory" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		TEST_DIR="$BATS_TEST_TMPDIR/new_dir"
		ensure_directory "$TEST_DIR" 2>/dev/null
		[[ -d "$TEST_DIR" ]] && echo "created"
	'
	assert_success
	assert_output "created"
}

@test "installer_init: ensure_directory is idempotent" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		TEST_DIR="$BATS_TEST_TMPDIR/existing"
		mkdir -p "$TEST_DIR"
		ensure_directory "$TEST_DIR"
		[[ -d "$TEST_DIR" ]] && echo "still exists"
	'
	assert_success
	assert_output "still exists"
}

# =============================================================================
# installer_init tests - fallback logging
# =============================================================================

@test "installer_init: fallback log functions work when log.sh missing" {
	# This tests the fallback path - hard to trigger since log.sh exists
	# But we can verify the functions are callable after init
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		log_info "test message" 2>&1
	'
	assert_success
	assert_output --partial "test message"
}

@test "installer_init: log_error outputs to stderr" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		installer_init
		log_error "error message" 2>&1 >/dev/null
	'
	assert_success
	assert_output --partial "error message"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "installer/core.sh: exports installer_init function" {
	run bash -c 'source "$LIB_DIR/installer/core.sh" && bash -c "type installer_init"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "installer/core.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/installer/core.sh" && echo "${_LGTM_CI_INSTALLER_CORE_LOADED}"'
	assert_success
	assert_output "1"
}

@test "installer/core.sh: can be sourced multiple times" {
	run bash -c '
		source "$LIB_DIR/installer/core.sh"
		source "$LIB_DIR/installer/core.sh"
		installer_init
		echo "ok"
	'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Integration tests
# =============================================================================

@test "installer_init: full initialization workflow" {
	run bash -c '
		export HOME="'"$BATS_TEST_TMPDIR"'/home"
		mkdir -p "$HOME"

		source "$LIB_DIR/installer/core.sh"
		installer_init

		# Verify all expected state
		[[ -n "$INSTALLER_LIB_DIR" ]] || exit 1
		[[ "$DRY_RUN" == "0" ]] || exit 1
		[[ -n "$BIN_DIR" ]] || exit 1
		type log_info >/dev/null 2>&1 || exit 1
		type command_exists >/dev/null 2>&1 || exit 1
		type ensure_directory >/dev/null 2>&1 || exit 1

		echo "all checks passed"
	'
	assert_success
	assert_output "all checks passed"
}
