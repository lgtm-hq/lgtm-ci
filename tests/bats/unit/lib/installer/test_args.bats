#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/installer/args.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# installer_show_help tests
# =============================================================================

@test "installer_show_help: displays basic help" {
	run bash -c '
		export TOOL_NAME="mytool"
		export TOOL_DESC="Install mytool for testing"
		source "$LIB_DIR/installer/args.sh"
		installer_show_help
	'
	assert_success
	assert_output --partial "Install mytool for testing"
	assert_output --partial "--help"
	assert_output --partial "--dry-run"
}

@test "installer_show_help: includes version option when TOOL_VERSION set" {
	run bash -c '
		export TOOL_NAME="mytool"
		export TOOL_DESC="Install mytool"
		export TOOL_VERSION="1.0.0"
		source "$LIB_DIR/installer/args.sh"
		installer_show_help
	'
	assert_success
	assert_output --partial "--version VER"
	assert_output --partial "default: 1.0.0"
	assert_output --partial "MYTOOL_VERSION"
}

@test "installer_show_help: includes extra help when TOOL_EXTRA_HELP set" {
	run bash -c '
		export TOOL_NAME="mytool"
		export TOOL_DESC="Install mytool"
		export TOOL_EXTRA_HELP="Additional notes here"
		source "$LIB_DIR/installer/args.sh"
		installer_show_help
	'
	assert_success
	assert_output --partial "Additional notes here"
}

@test "installer_show_help: shows BIN_DIR info" {
	run bash -c '
		export TOOL_NAME="mytool"
		export TOOL_DESC="Install mytool"
		source "$LIB_DIR/installer/args.sh"
		installer_show_help
	'
	assert_success
	assert_output --partial "BIN_DIR"
	assert_output --partial "~/.local/bin"
}

# =============================================================================
# installer_parse_args tests
# =============================================================================

@test "installer_parse_args: sets DRY_RUN with --dry-run" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args --dry-run
		echo "DRY_RUN=$DRY_RUN"
	'
	assert_success
	assert_output "DRY_RUN=1"
}

@test "installer_parse_args: sets TOOL_VERSION with --version VALUE" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args --version 2.0.0
		echo "TOOL_VERSION=$TOOL_VERSION"
	'
	assert_success
	assert_output "TOOL_VERSION=2.0.0"
}

@test "installer_parse_args: exits 0 for --help" {
	run bash -c '
		export TOOL_NAME="mytool"
		export TOOL_DESC="Install mytool"
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args --help
	'
	assert_success
	assert_output --partial "--help"
}

@test "installer_parse_args: exits 0 for -h" {
	run bash -c '
		export TOOL_NAME="mytool"
		export TOOL_DESC="Install mytool"
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args -h
	'
	assert_success
	assert_output --partial "--help"
}

@test "installer_parse_args: warns on unknown option" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args --unknown-flag 2>&1
	'
	assert_success
	assert_output --partial "Unknown option"
}

@test "installer_parse_args: collects positional args in INSTALLER_ARGS" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args arg1 arg2
		echo "${INSTALLER_ARGS[0]}"
		echo "${INSTALLER_ARGS[1]}"
	'
	assert_success
	assert_line "arg1"
	assert_line "arg2"
}

@test "installer_parse_args: exits 1 for --version without value" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args --version 2>&1
	'
	assert_failure
	assert_output --partial "requires a version argument"
}

@test "installer_parse_args: exits 1 for --version followed by flag" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args --version --dry-run 2>&1
	'
	assert_failure
	assert_output --partial "requires a version argument"
}

@test "installer_parse_args: handles mixed options and positional args" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		installer_parse_args --dry-run arg1 --version 3.0.0 arg2
		echo "DRY_RUN=$DRY_RUN"
		echo "TOOL_VERSION=$TOOL_VERSION"
		echo "ARGS=${INSTALLER_ARGS[*]}"
	'
	assert_success
	assert_line "DRY_RUN=1"
	assert_line "TOOL_VERSION=3.0.0"
	assert_line "ARGS=arg1 arg2"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "args.sh: exports installer_show_help function" {
	run bash -c 'source "$LIB_DIR/installer/args.sh" && declare -f installer_show_help >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "args.sh: exports installer_parse_args function" {
	run bash -c 'source "$LIB_DIR/installer/args.sh" && declare -f installer_parse_args >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "args.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/installer/args.sh"
		source "$LIB_DIR/installer/args.sh"
		declare -f installer_parse_args >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "args.sh: sets _LGTM_CI_INSTALLER_ARGS_LOADED guard" {
	run bash -c 'source "$LIB_DIR/installer/args.sh" && echo "${_LGTM_CI_INSTALLER_ARGS_LOADED}"'
	assert_success
	assert_output "1"
}
