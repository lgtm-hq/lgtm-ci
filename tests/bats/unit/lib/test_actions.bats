#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/actions.sh (aggregator)

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

@test "actions.sh: sources log.sh" {
	run bash -c 'source "$LIB_DIR/actions.sh" && log_info "test" 2>&1'
	assert_success
	assert_output --partial "[INFO]"
}

@test "actions.sh: sources github.sh" {
	run bash -c 'source "$LIB_DIR/actions.sh" && declare -f set_github_output >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "actions.sh: makes die function available" {
	run bash -c 'source "$LIB_DIR/actions.sh" && die "test error" 2>&1'
	assert_failure
	assert_output --partial "[ERROR]"
	assert_output --partial "test error"
}

@test "actions.sh: makes log_error function available" {
	run bash -c 'source "$LIB_DIR/actions.sh" && log_error "error message" 2>&1'
	assert_success
	assert_output --partial "[ERROR]"
	assert_output --partial "error message"
}

@test "actions.sh: makes log_success function available" {
	run bash -c 'source "$LIB_DIR/actions.sh" && log_success "done" 2>&1'
	assert_success
	assert_output --partial "[SUCCESS]"
}

@test "actions.sh: makes log_warn function available" {
	run bash -c 'source "$LIB_DIR/actions.sh" && log_warn "warning" 2>&1'
	assert_success
	assert_output --partial "[WARN]"
}

# =============================================================================
# Optional library tests
# =============================================================================

@test "actions.sh: optionally sources sbom.sh when available" {
	run bash -c 'source "$LIB_DIR/actions.sh" && declare -f validate_sbom_format >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "actions.sh: optionally sources installer.sh when available" {
	run bash -c 'source "$LIB_DIR/actions.sh" && (declare -f install_tool >/dev/null || declare -f download_with_retries >/dev/null) && echo "loaded"'
	# May or may not be loaded depending on installer.sh existence
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "actions.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/actions.sh"
		source "$LIB_DIR/actions.sh"
		source "$LIB_DIR/actions.sh"
		log_info "test" 2>&1
	'
	assert_success
	assert_output --partial "[INFO]"
}

@test "actions.sh: sets _LGTM_CI_ACTIONS_LOADED guard" {
	run bash -c 'source "$LIB_DIR/actions.sh" && echo "${_LGTM_CI_ACTIONS_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Integration tests
# =============================================================================

@test "actions.sh: provides GitHub Actions helpers" {
	run bash -c '
		source "$LIB_DIR/actions.sh"
		export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
		touch "$GITHUB_OUTPUT"
		set_github_output "key" "value"
		cat "$GITHUB_OUTPUT"
	'
	assert_success
	assert_output "key=value"
}

@test "actions.sh: provides GitHub summary helpers" {
	run bash -c '
		source "$LIB_DIR/actions.sh"
		export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
		touch "$GITHUB_STEP_SUMMARY"
		add_github_summary "## Test"
		cat "$GITHUB_STEP_SUMMARY"
	'
	assert_success
	assert_output "## Test"
}
