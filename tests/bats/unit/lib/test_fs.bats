#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/fs.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

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
# command_exists tests
# =============================================================================

@test "command_exists: returns true for bash" {
	run bash -c 'source "$LIB_DIR/fs.sh" && command_exists bash && echo "exists"'
	assert_success
	assert_output "exists"
}

@test "command_exists: returns true for sh" {
	run bash -c 'source "$LIB_DIR/fs.sh" && command_exists sh && echo "exists"'
	assert_success
	assert_output "exists"
}

@test "command_exists: returns false for nonexistent command" {
	run bash -c 'source "$LIB_DIR/fs.sh" && command_exists nonexistent_command_xyz123 || echo "not found"'
	assert_success
	assert_output "not found"
}

@test "command_exists: handles empty argument" {
	run bash -c 'source "$LIB_DIR/fs.sh" && command_exists "" || echo "not found"'
	assert_success
	assert_output "not found"
}

# =============================================================================
# require_command tests
# =============================================================================

@test "require_command: succeeds for existing command" {
	run bash -c 'source "$LIB_DIR/fs.sh" && require_command bash && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "require_command: fails for nonexistent command" {
	run bash -c 'source "$LIB_DIR/fs.sh" && require_command nonexistent_xyz123 2>&1'
	assert_failure
	assert_output --partial "Required command not found: nonexistent_xyz123"
}

@test "require_command: includes install hint when provided" {
	run bash -c 'source "$LIB_DIR/fs.sh" && require_command nonexistent_xyz123 "Try: brew install xyz" 2>&1'
	assert_failure
	assert_output --partial "Required command not found: nonexistent_xyz123"
	assert_output --partial "Try: brew install xyz"
}

@test "require_command: hint is optional" {
	run bash -c 'source "$LIB_DIR/fs.sh" && require_command bash'
	assert_success
}

# =============================================================================
# ensure_directory tests
# =============================================================================

@test "ensure_directory: creates new directory" {
	local test_dir="${BATS_TEST_TMPDIR}/new_dir"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && ensure_directory \"$test_dir\" && [[ -d \"$test_dir\" ]] && echo created"
	assert_success
	assert_output --partial "created"
}

@test "ensure_directory: creates nested directories" {
	local test_dir="${BATS_TEST_TMPDIR}/a/b/c/d"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && ensure_directory \"$test_dir\" && [[ -d \"$test_dir\" ]] && echo created"
	assert_success
	assert_output --partial "created"
}

@test "ensure_directory: is idempotent" {
	local test_dir="${BATS_TEST_TMPDIR}/existing"
	mkdir -p "$test_dir"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && ensure_directory \"$test_dir\" && echo ok"
	assert_success
	assert_output "ok"
}

@test "ensure_directory: logs when creating directory" {
	local test_dir="${BATS_TEST_TMPDIR}/logged_dir"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && ensure_directory \"$test_dir\" 2>&1"
	assert_success
	assert_output --partial "Creating directory"
}

# =============================================================================
# require_file tests
# =============================================================================

@test "require_file: succeeds for existing file" {
	local test_file="${BATS_TEST_TMPDIR}/existing_file.txt"
	echo "content" >"$test_file"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && require_file \"$test_file\" && echo ok"
	assert_success
	assert_output "ok"
}

@test "require_file: fails for nonexistent file" {
	run bash -c "source \"\$LIB_DIR/fs.sh\" && require_file \"${BATS_TEST_TMPDIR}/nonexistent.txt\" 2>&1"
	assert_failure
	assert_output --partial "Required file not found"
}

@test "require_file: fails for directory (not file)" {
	local test_dir="${BATS_TEST_TMPDIR}/a_directory"
	mkdir -p "$test_dir"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && require_file \"$test_dir\" 2>&1"
	assert_failure
	assert_output --partial "Required file not found"
}

# =============================================================================
# check_file_exists tests
# =============================================================================

@test "check_file_exists: returns 0 for existing file" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/check_file.txt"
	echo "content" >"$test_file"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && check_file_exists \"$test_file\" 2>&1"
	assert_success
	assert_output --partial "found"
}

@test "check_file_exists: returns 1 for nonexistent file" {
	run bash -c "source \"\$LIB_DIR/fs.sh\" && check_file_exists \"${BATS_TEST_TMPDIR}/nonexistent.txt\" 2>&1"
	assert_failure
	assert_output --partial "not found"
}

@test "check_file_exists: uses custom description" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/config.json"
	echo "{}" >"$test_file"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && check_file_exists \"$test_file\" \"Config file\" 2>&1"
	assert_success
	assert_output --partial "Config file found"
}

@test "check_file_exists: logs file size in verbose mode" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/sized_file.txt"
	echo "some content here" >"$test_file"
	run bash -c "export VERBOSE=1; source \"\$LIB_DIR/fs.sh\" && check_file_exists \"$test_file\" 2>&1"
	assert_success
	assert_output --partial "bytes"
}

# =============================================================================
# check_dir_exists tests
# =============================================================================

@test "check_dir_exists: returns 0 for existing directory" {
	local test_dir="${BATS_TEST_TMPDIR}/check_dir"
	mkdir -p "$test_dir"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && check_dir_exists \"$test_dir\" 2>&1"
	assert_success
	assert_output --partial "found"
}

@test "check_dir_exists: returns 1 for nonexistent directory" {
	run bash -c "source \"\$LIB_DIR/fs.sh\" && check_dir_exists \"${BATS_TEST_TMPDIR}/nonexistent_dir\" 2>&1"
	assert_failure
	assert_output --partial "not found"
}

@test "check_dir_exists: uses custom description" {
	local test_dir="${BATS_TEST_TMPDIR}/build"
	mkdir -p "$test_dir"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && check_dir_exists \"$test_dir\" \"Build directory\" 2>&1"
	assert_success
	assert_output --partial "Build directory found"
}

@test "check_dir_exists: returns 1 for file (not directory)" {
	local test_file="${BATS_TEST_TMPDIR}/a_file.txt"
	echo "content" >"$test_file"
	run bash -c "source \"\$LIB_DIR/fs.sh\" && check_dir_exists \"$test_file\" 2>&1"
	assert_failure
	assert_output --partial "not found"
}

# =============================================================================
# create_temp_dir tests
# =============================================================================

@test "create_temp_dir: creates directory with lgtm-ci prefix" {
	# Note: We check the path format, not directory existence, because the EXIT trap
	# in the subshell cleans up the temp dir when the command substitution exits
	run bash -c 'source "$LIB_DIR/fs.sh" && tmpdir=$(create_temp_dir) && echo "$tmpdir"'
	assert_success
	assert_output --partial "lgtm-ci"
}

@test "create_temp_dir: returns directory path" {
	run bash -c 'source "$LIB_DIR/fs.sh" && tmpdir=$(create_temp_dir) && echo "$tmpdir"'
	assert_success
	assert_output --regexp "^/.*lgtm-ci\."
}

@test "create_temp_dir: cleans up on exit" {
	# Run in subshell to trigger EXIT trap
	run bash -c '
		source "$LIB_DIR/fs.sh"
		tmpdir=$(create_temp_dir)
		# Store path for parent to check
		echo "$tmpdir"
	'
	assert_success
	# Assert output is non-empty (create_temp_dir returned a path)
	[[ -n "$output" ]]
	# After the subshell exits, the directory should be cleaned up
	[[ ! -d "$output" ]]
}

@test "create_temp_dir: preserves existing EXIT trap" {
	run bash -c '
		source "$LIB_DIR/fs.sh"
		trap "echo existing_trap_called" EXIT
		tmpdir=$(create_temp_dir)
		exit 0
	'
	assert_success
	assert_output --partial "existing_trap_called"
}

@test "create_temp_dir: respects TMPDIR environment variable" {
	local custom_tmp="${BATS_TEST_TMPDIR}/custom_tmp"
	mkdir -p "$custom_tmp"
	# Note: TMPDIR must be exported before sourcing the library, not inline
	run bash -c "export TMPDIR=\"$custom_tmp\"; source \"\$LIB_DIR/fs.sh\" && tmpdir=\$(create_temp_dir) && echo \"\$tmpdir\""
	assert_success
	assert_output --partial "$custom_tmp"
}

# =============================================================================
# Fallback die function tests
# =============================================================================

@test "fs.sh: provides fallback die when log.sh unavailable" {
	# Test by sourcing fs.sh from a directory without log.sh
	run bash -c '
		mkdir -p "$BATS_TEST_TMPDIR/isolated"
		cp "$LIB_DIR/fs.sh" "$BATS_TEST_TMPDIR/isolated/"
		cd "$BATS_TEST_TMPDIR/isolated"
		source ./fs.sh
		die "test error" 2>&1
	'
	assert_failure
	assert_output --partial "test error"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "fs.sh: exports command_exists function" {
	run bash -c 'source "$LIB_DIR/fs.sh" && bash -c "command_exists bash && echo yes"'
	assert_success
	assert_output "yes"
}

@test "fs.sh: exports require_command function" {
	run bash -c 'source "$LIB_DIR/fs.sh" && bash -c "require_command bash && echo yes"'
	assert_success
	assert_output "yes"
}

@test "fs.sh: exports ensure_directory function" {
	run bash -c "source \"\$LIB_DIR/fs.sh\" && bash -c 'ensure_directory \"${BATS_TEST_TMPDIR}/export_test\"'"
	assert_success
}

@test "fs.sh: exports create_temp_dir function" {
	run bash -c 'source "$LIB_DIR/fs.sh" && bash -c "create_temp_dir" >/dev/null'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "fs.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/fs.sh"
		source "$LIB_DIR/fs.sh"
		source "$LIB_DIR/fs.sh"
		command_exists bash && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "fs.sh: sets _LGTM_CI_FS_LOADED guard" {
	run bash -c 'source "$LIB_DIR/fs.sh" && echo "${_LGTM_CI_FS_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Integration tests
# =============================================================================

@test "fs.sh: sources log.sh automatically" {
	run bash -c 'source "$LIB_DIR/fs.sh" && log_info "from fs.sh" 2>&1'
	assert_success
	assert_output --partial "[INFO]"
}

@test "fs.sh: ensure_directory uses log_info when available" {
	run bash -c "source \"\$LIB_DIR/fs.sh\" && ensure_directory \"${BATS_TEST_TMPDIR}/logged_create\" 2>&1"
	assert_success
	assert_output --partial "[INFO]"
	assert_output --partial "Creating directory"
}
