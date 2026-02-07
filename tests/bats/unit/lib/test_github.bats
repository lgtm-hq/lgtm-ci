#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/github.sh (aggregator)

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

@test "github.sh: sources github/env.sh" {
	run bash -c 'source "$LIB_DIR/github.sh" && declare -f is_ci >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "github.sh: sources github/output.sh" {
	run bash -c 'source "$LIB_DIR/github.sh" && declare -f set_github_output >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "github.sh: sources github/summary.sh" {
	run bash -c 'source "$LIB_DIR/github.sh" && declare -f add_github_summary >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "github.sh: sources github/format.sh" {
	run bash -c 'source "$LIB_DIR/github.sh" && declare -f get_github_pages_url >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "github.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/github.sh"
		source "$LIB_DIR/github.sh"
		declare -f is_ci >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "github.sh: sets _LGTM_CI_GITHUB_LOADED guard" {
	run bash -c 'source "$LIB_DIR/github.sh" && echo "${_LGTM_CI_GITHUB_LOADED}"'
	assert_success
	assert_output "1"
}
