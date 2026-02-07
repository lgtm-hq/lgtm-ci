#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/log.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir

	# Source the library in a subshell-friendly way
	# Use a fresh bash to avoid readonly variable issues
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# Color codes tests
# =============================================================================

@test "log.sh: exports LGTM_CI color codes" {
	run bash -c 'source "$LIB_DIR/log.sh" && echo "${LGTM_CI_RED}test"'
	assert_success
	assert_output --partial "test"
}

@test "log.sh: exports legacy color aliases" {
	run bash -c '
		source "$LIB_DIR/log.sh"
		declare -p RED GREEN YELLOW BLUE NC >/dev/null 2>&1
	'
	assert_success
}

@test "log.sh: color codes are readonly" {
	run bash -c 'source "$LIB_DIR/log.sh" && LGTM_CI_RED="changed" 2>&1'
	assert_failure
	assert_output --partial "readonly"
}

# =============================================================================
# log_info tests
# =============================================================================

@test "log_info: outputs message with INFO prefix" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_info "test message" 2>&1'
	assert_success
	assert_output --partial "[INFO]"
	assert_output --partial "test message"
}

@test "log_info: outputs to stderr" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_info "test" 2>&1 1>/dev/null'
	assert_success
	assert_output --partial "[INFO]"
}

@test "log_info: handles multiple arguments" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_info "arg1" "arg2" "arg3" 2>&1'
	assert_success
	assert_output --partial "arg1 arg2 arg3"
}

@test "log_info: handles empty message" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_info "" 2>&1'
	assert_success
	assert_output --partial "[INFO]"
}

# =============================================================================
# log_success tests
# =============================================================================

@test "log_success: outputs message with SUCCESS prefix" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_success "completed" 2>&1'
	assert_success
	assert_output --partial "[SUCCESS]"
	assert_output --partial "completed"
}

@test "log_success: uses green color" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_success "done" 2>&1'
	assert_success
	# Check for green ANSI code
	assert_output --partial $'\033[0;32m'
}

# =============================================================================
# log_warn tests
# =============================================================================

@test "log_warn: outputs message with WARN prefix" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_warn "warning message" 2>&1'
	assert_success
	assert_output --partial "[WARN]"
	assert_output --partial "warning message"
}

@test "log_warn: uses yellow color" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_warn "caution" 2>&1'
	assert_success
	# Check for yellow ANSI code
	assert_output --partial $'\033[1;33m'
}

@test "log_warning: is alias for log_warn" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_warning "alias test" 2>&1'
	assert_success
	assert_output --partial "[WARN]"
	assert_output --partial "alias test"
}

# =============================================================================
# log_error tests
# =============================================================================

@test "log_error: outputs message with ERROR prefix" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_error "error message" 2>&1'
	assert_success
	assert_output --partial "[ERROR]"
	assert_output --partial "error message"
}

@test "log_error: uses red color" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_error "failure" 2>&1'
	assert_success
	# Check for red ANSI code
	assert_output --partial $'\033[0;31m'
}

@test "log_error: outputs to stderr not stdout" {
	run bash -c 'source "$LIB_DIR/log.sh" && log_error "test" 2>/dev/null'
	assert_success
	refute_output
}

# =============================================================================
# log_verbose tests
# =============================================================================

@test "log_verbose: outputs nothing when VERBOSE is unset" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'unset VERBOSE; source "$LIB_DIR/log.sh" && log_verbose "hidden" 2>&1'
	assert_success
	refute_output
}

@test "log_verbose: outputs nothing when VERBOSE is empty" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'export VERBOSE=""; source "$LIB_DIR/log.sh" && log_verbose "hidden" 2>&1'
	assert_success
	refute_output
}

@test "log_verbose: outputs when VERBOSE=1" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'export VERBOSE=1; source "$LIB_DIR/log.sh" && log_verbose "visible" 2>&1'
	assert_success
	assert_output --partial "[VERBOSE]"
	assert_output --partial "visible"
}

@test "log_verbose: outputs when VERBOSE=true" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'export VERBOSE=true; source "$LIB_DIR/log.sh" && log_verbose "visible" 2>&1'
	assert_success
	assert_output --partial "[VERBOSE]"
}

@test "log_verbose: outputs when VERBOSE=TRUE (case insensitive)" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'export VERBOSE=TRUE; source "$LIB_DIR/log.sh" && log_verbose "visible" 2>&1'
	assert_success
	assert_output --partial "[VERBOSE]"
}

@test "log_verbose: does not output when VERBOSE=0" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'export VERBOSE=0; source "$LIB_DIR/log.sh" && log_verbose "hidden" 2>&1'
	assert_success
	refute_output
}

@test "log_verbose: does not output when VERBOSE=false" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'export VERBOSE=false; source "$LIB_DIR/log.sh" && log_verbose "hidden" 2>&1'
	assert_success
	refute_output
}

# =============================================================================
# die tests
# =============================================================================

@test "die: exits with code 1" {
	run bash -c 'source "$LIB_DIR/log.sh" && die "fatal error" 2>&1'
	assert_failure
	assert_exit_code 1
}

@test "die: outputs error message" {
	run bash -c 'source "$LIB_DIR/log.sh" && die "fatal error" 2>&1'
	assert_failure
	assert_output --partial "[ERROR]"
	assert_output --partial "fatal error"
}

@test "die: handles multiple arguments" {
	run bash -c 'source "$LIB_DIR/log.sh" && die "error:" "details" "here" 2>&1'
	assert_failure
	assert_output --partial "error: details here"
}

# =============================================================================
# die_unknown_step tests
# =============================================================================

@test "die_unknown_step: exits with code 1" {
	run bash -c 'source "$LIB_DIR/log.sh" && die_unknown_step "bad_step" 2>&1'
	assert_failure
	assert_exit_code 1
}

@test "die_unknown_step: outputs step name" {
	run bash -c 'source "$LIB_DIR/log.sh" && die_unknown_step "invalid_step" 2>&1'
	assert_failure
	assert_output --partial "Unknown step: invalid_step"
}

@test "die_unknown_step: handles missing argument" {
	run bash -c 'source "$LIB_DIR/log.sh" && die_unknown_step 2>&1'
	assert_failure
	assert_output --partial "Unknown step: unknown"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "log.sh: exports log_info function" {
	run bash -c 'source "$LIB_DIR/log.sh" && bash -c "log_info test" 2>&1'
	assert_success
	assert_output --partial "[INFO]"
}

@test "log.sh: exports log_success function" {
	run bash -c 'source "$LIB_DIR/log.sh" && bash -c "log_success test" 2>&1'
	assert_success
	assert_output --partial "[SUCCESS]"
}

@test "log.sh: exports log_warn function" {
	run bash -c 'source "$LIB_DIR/log.sh" && bash -c "log_warn test" 2>&1'
	assert_success
	assert_output --partial "[WARN]"
}

@test "log.sh: exports log_error function" {
	run bash -c 'source "$LIB_DIR/log.sh" && bash -c "log_error test" 2>&1'
	assert_success
	assert_output --partial "[ERROR]"
}

@test "log.sh: exports die function" {
	run bash -c 'source "$LIB_DIR/log.sh" && bash -c "die test" 2>&1'
	assert_failure
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "log.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/log.sh"
		log_info "sourced three times" 2>&1
	'
	assert_success
	assert_output --partial "sourced three times"
}

@test "log.sh: sets _LGTM_CI_LOG_LOADED guard" {
	run bash -c 'source "$LIB_DIR/log.sh" && echo "${_LGTM_CI_LOG_LOADED}"'
	assert_success
	assert_output "1"
}
