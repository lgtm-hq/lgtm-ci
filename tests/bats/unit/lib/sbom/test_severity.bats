#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/sbom/severity.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# severity_to_number tests
# =============================================================================

@test "severity_to_number: returns 5 for critical" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "critical"'
	assert_success
	assert_output "5"
}

@test "severity_to_number: returns 4 for high" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "high"'
	assert_success
	assert_output "4"
}

@test "severity_to_number: returns 3 for medium" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "medium"'
	assert_success
	assert_output "3"
}

@test "severity_to_number: returns 2 for low" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "low"'
	assert_success
	assert_output "2"
}

@test "severity_to_number: returns 1 for negligible" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "negligible"'
	assert_success
	assert_output "1"
}

@test "severity_to_number: returns 0 for unknown" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "unknown"'
	assert_success
	assert_output "0"
}

@test "severity_to_number: handles uppercase input" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "CRITICAL"'
	assert_success
	assert_output "5"
}

@test "severity_to_number: handles mixed case input" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_to_number "High"'
	assert_success
	assert_output "4"
}

# =============================================================================
# number_to_severity tests
# =============================================================================

@test "number_to_severity: returns critical for 5" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && number_to_severity 5'
	assert_success
	assert_output "critical"
}

@test "number_to_severity: returns high for 4" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && number_to_severity 4'
	assert_success
	assert_output "high"
}

@test "number_to_severity: returns medium for 3" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && number_to_severity 3'
	assert_success
	assert_output "medium"
}

@test "number_to_severity: returns low for 2" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && number_to_severity 2'
	assert_success
	assert_output "low"
}

@test "number_to_severity: returns negligible for 1" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && number_to_severity 1'
	assert_success
	assert_output "negligible"
}

@test "number_to_severity: returns unknown for 0" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && number_to_severity 0'
	assert_success
	assert_output "unknown"
}

@test "number_to_severity: returns unknown for invalid number" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && number_to_severity 99'
	assert_success
	assert_output "unknown"
}

# =============================================================================
# compare_severity tests
# =============================================================================

@test "compare_severity: returns -1 when first < second" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && compare_severity "low" "high"'
	assert_success
	assert_output "-1"
}

@test "compare_severity: returns 0 when equal" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && compare_severity "high" "high"'
	assert_success
	assert_output "0"
}

@test "compare_severity: returns 1 when first > second" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && compare_severity "critical" "medium"'
	assert_success
	assert_output "1"
}

@test "compare_severity: handles mixed case" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && compare_severity "HIGH" "low"'
	assert_success
	assert_output "1"
}

# =============================================================================
# severity_meets_threshold tests
# =============================================================================

@test "severity_meets_threshold: returns true when severity >= threshold" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_meets_threshold "high" "medium" && echo "meets"'
	assert_success
	assert_output "meets"
}

@test "severity_meets_threshold: returns true when equal" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_meets_threshold "high" "high" && echo "meets"'
	assert_success
	assert_output "meets"
}

@test "severity_meets_threshold: returns false when severity < threshold" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_meets_threshold "low" "high" || echo "below"'
	assert_success
	assert_output "below"
}

# =============================================================================
# should_fail_on_severity tests
# =============================================================================

@test "should_fail_on_severity: returns false when fail_on is empty" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && should_fail_on_severity "critical" "" || echo "no-fail"'
	assert_success
	assert_output "no-fail"
}

@test "should_fail_on_severity: returns false when fail_on is none" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && should_fail_on_severity "critical" "none" || echo "no-fail"'
	assert_success
	assert_output "no-fail"
}

@test "should_fail_on_severity: returns true when severity >= fail_on" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && should_fail_on_severity "high" "medium" && echo "fail"'
	assert_success
	assert_output "fail"
}

@test "should_fail_on_severity: returns false when severity < fail_on" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && should_fail_on_severity "low" "high" || echo "no-fail"'
	assert_success
	assert_output "no-fail"
}

# =============================================================================
# severity_emoji tests
# =============================================================================

@test "severity_emoji: returns red_circle for critical" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_emoji "critical"'
	assert_success
	assert_output ":red_circle:"
}

@test "severity_emoji: returns orange_circle for high" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_emoji "high"'
	assert_success
	assert_output ":orange_circle:"
}

@test "severity_emoji: returns yellow_circle for medium" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_emoji "medium"'
	assert_success
	assert_output ":yellow_circle:"
}

@test "severity_emoji: returns blue_circle for low" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_emoji "low"'
	assert_success
	assert_output ":blue_circle:"
}

@test "severity_emoji: returns white_circle for negligible" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_emoji "negligible"'
	assert_success
	assert_output ":white_circle:"
}

@test "severity_emoji: returns black_circle for unknown" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_emoji "unknown"'
	assert_success
	assert_output ":black_circle:"
}

@test "severity_emoji: returns black_circle for unrecognized input" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_emoji "xyz"'
	assert_success
	assert_output ":black_circle:"
}

# =============================================================================
# severity_color tests
# =============================================================================

@test "severity_color: returns red escape for critical" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "critical" | cat -v'
	assert_success
	assert_output --partial "31m"
}

@test "severity_color: returns bright red escape for high" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "high" | cat -v'
	assert_success
	assert_output --partial "91m"
}

@test "severity_color: returns yellow escape for medium" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "medium" | cat -v'
	assert_success
	assert_output --partial "33m"
}

@test "severity_color: returns blue escape for low" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "low" | cat -v'
	assert_success
	assert_output --partial "34m"
}

@test "severity_color: returns gray escape for negligible" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "negligible" | cat -v'
	assert_success
	assert_output --partial "90m"
}

@test "severity_color: returns reset escape for unknown" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "unknown" | cat -v'
	assert_success
	assert_output --partial "0m"
}

@test "severity_color: returns reset escape for unrecognized input" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "xyz" | cat -v'
	assert_success
	assert_output --partial "0m"
}

@test "severity_color: handles uppercase input" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && severity_color "CRITICAL" | cat -v'
	assert_success
	assert_output --partial "31m"
}

# =============================================================================
# Constants tests
# =============================================================================

@test "severity.sh: defines SEVERITY_CRITICAL constant" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && echo "$SEVERITY_CRITICAL"'
	assert_success
	assert_output "5"
}

@test "severity.sh: defines SEVERITY_HIGH constant" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && echo "$SEVERITY_HIGH"'
	assert_success
	assert_output "4"
}

@test "severity.sh: defines SEVERITY_MEDIUM constant" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && echo "$SEVERITY_MEDIUM"'
	assert_success
	assert_output "3"
}

@test "severity.sh: defines SEVERITY_LOW constant" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && echo "$SEVERITY_LOW"'
	assert_success
	assert_output "2"
}

@test "severity.sh: defines SEVERITY_NEGLIGIBLE constant" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && echo "$SEVERITY_NEGLIGIBLE"'
	assert_success
	assert_output "1"
}

@test "severity.sh: defines SEVERITY_UNKNOWN constant" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && echo "$SEVERITY_UNKNOWN"'
	assert_success
	assert_output "0"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "severity.sh: can be sourced multiple times without error" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c '
		source "$LIB_DIR/sbom/severity.sh"
		source "$LIB_DIR/sbom/severity.sh"
		source "$LIB_DIR/sbom/severity.sh"
		severity_to_number "high"
	'
	assert_success
	assert_output "4"
}

@test "severity.sh: sets _LGTM_CI_SBOM_SEVERITY_LOADED guard" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/sbom/severity.sh" && echo "${_LGTM_CI_SBOM_SEVERITY_LOADED}"'
	assert_success
	assert_output "1"
}
