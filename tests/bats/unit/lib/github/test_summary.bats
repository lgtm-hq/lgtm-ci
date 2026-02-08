#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/github/summary.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
	teardown_github_env
}

# =============================================================================
# add_github_summary tests
# =============================================================================

@test "add_github_summary: appends content to GITHUB_STEP_SUMMARY" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary "## Test Results"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_output "## Test Results"
}

@test "add_github_summary: appends multiple arguments as single line" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary "Status:" "PASSED"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_output "Status: PASSED"
}

@test "add_github_summary: does nothing when GITHUB_STEP_SUMMARY not set" {
	run bash -c '
		unset GITHUB_STEP_SUMMARY
		source "$LIB_DIR/github/summary.sh"
		add_github_summary "should not appear anywhere"
	'
	assert_success
	refute_output
}

@test "add_github_summary: handles multiple calls (appending)" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary "Line 1"
		add_github_summary "Line 2"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_line "Line 1"
	assert_line "Line 2"
}

# =============================================================================
# add_github_summary_row tests
# =============================================================================

@test "add_github_summary_row: formats single column as table row" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_row "Only Column"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_output "| Only Column |"
}

@test "add_github_summary_row: formats multiple columns as table row" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_row "Name" "Value" "Status"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_output "| Name | Value | Status |"
}

@test "add_github_summary_row: handles empty arguments gracefully" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_row
	'
	assert_success
	# Should do nothing, not crash
}

@test "add_github_summary_row: does nothing when GITHUB_STEP_SUMMARY not set" {
	run bash -c '
		unset GITHUB_STEP_SUMMARY
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_row "col1" "col2"
	'
	assert_success
}

@test "add_github_summary_row: can build a markdown table" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_row "Metric" "Value"
		add_github_summary_row "---" "---"
		add_github_summary_row "Tests" "42"
		add_github_summary_row "Coverage" "85%"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_line "| Metric | Value |"
	assert_line "| --- | --- |"
	assert_line "| Tests | 42 |"
	assert_line "| Coverage | 85% |"
}

# =============================================================================
# add_github_summary_details tests
# =============================================================================

@test "add_github_summary_details: creates collapsible section" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_details "Click to expand" "Hidden content here"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_line "<details>"
	assert_line "<summary>Click to expand</summary>"
	assert_line "Hidden content here"
	assert_line "</details>"
}

@test "add_github_summary_details: handles multiline content" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_details "Logs" "Line 1
Line 2
Line 3"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_output --partial "Line 1"
	assert_output --partial "Line 2"
	assert_output --partial "Line 3"
}

@test "add_github_summary_details: does nothing when GITHUB_STEP_SUMMARY not set" {
	run bash -c '
		unset GITHUB_STEP_SUMMARY
		source "$LIB_DIR/github/summary.sh"
		add_github_summary_details "Title" "Content"
	'
	assert_success
}

# =============================================================================
# Function export tests
# =============================================================================

@test "github/summary.sh: exports add_github_summary function" {
	run bash -c 'source "$LIB_DIR/github/summary.sh" && bash -c "type add_github_summary"'
	assert_success
}

@test "github/summary.sh: exports add_github_summary_row function" {
	run bash -c 'source "$LIB_DIR/github/summary.sh" && bash -c "type add_github_summary_row"'
	assert_success
}

@test "github/summary.sh: exports add_github_summary_details function" {
	run bash -c 'source "$LIB_DIR/github/summary.sh" && bash -c "type add_github_summary_details"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "github/summary.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/github/summary.sh" && echo "${_LGTM_CI_GITHUB_SUMMARY_LOADED}"'
	assert_success
	assert_output "1"
}

@test "github/summary.sh: can be sourced multiple times" {
	run bash -c '
		source "$LIB_DIR/github/summary.sh"
		source "$LIB_DIR/github/summary.sh"
		add_github_summary "test"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_output "test"
}
