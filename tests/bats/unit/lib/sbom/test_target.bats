#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/sbom/target.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# resolve_scan_target tests
# =============================================================================

@test "resolve_scan_target: formats dir target with prefix" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && resolve_scan_target "/path/to/dir" "dir"'
	assert_success
	assert_output "dir:/path/to/dir"
}

@test "resolve_scan_target: formats directory target with prefix" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && resolve_scan_target "/path/to/dir" "directory"'
	assert_success
	assert_output "dir:/path/to/dir"
}

@test "resolve_scan_target: formats image target without prefix" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && resolve_scan_target "nginx:latest" "image"'
	assert_success
	assert_output "nginx:latest"
}

@test "resolve_scan_target: formats container target without prefix" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && resolve_scan_target "alpine:3.18" "container"'
	assert_success
	assert_output "alpine:3.18"
}

@test "resolve_scan_target: formats file target with prefix" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && resolve_scan_target "/path/to/file.tar" "file"'
	assert_success
	assert_output "file:/path/to/file.tar"
}

@test "resolve_scan_target: formats sbom target with prefix" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && resolve_scan_target "/path/to/sbom.json" "sbom"'
	assert_success
	assert_output "sbom:/path/to/sbom.json"
}

@test "resolve_scan_target: fails for unsupported target type" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && resolve_scan_target "/path" "invalid" 2>&1'
	assert_failure
	assert_output --partial "Unsupported target type"
}

# =============================================================================
# validate_scan_target tests
# =============================================================================

@test "validate_scan_target: returns true for existing directory" {
	local test_dir="${BATS_TEST_TMPDIR}/exists"
	mkdir -p "$test_dir"
	run bash -c "source \"\$LIB_DIR/sbom/target.sh\" && validate_scan_target \"$test_dir\" \"dir\" && echo \"valid\""
	assert_success
	assert_output "valid"
}

@test "validate_scan_target: returns false for nonexistent directory" {
	run bash -c "source \"\$LIB_DIR/sbom/target.sh\" && validate_scan_target \"${BATS_TEST_TMPDIR}/nonexistent\" \"dir\" || echo \"invalid\""
	assert_success
	assert_output "invalid"
}

@test "validate_scan_target: returns true for existing file" {
	local test_file="${BATS_TEST_TMPDIR}/exists.txt"
	echo "content" >"$test_file"
	run bash -c "source \"\$LIB_DIR/sbom/target.sh\" && validate_scan_target \"$test_file\" \"file\" && echo \"valid\""
	assert_success
	assert_output "valid"
}

@test "validate_scan_target: returns false for nonexistent file" {
	run bash -c "source \"\$LIB_DIR/sbom/target.sh\" && validate_scan_target \"${BATS_TEST_TMPDIR}/nonexistent.txt\" \"file\" || echo \"invalid\""
	assert_success
	assert_output "invalid"
}

@test "validate_scan_target: always returns true for image type" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && validate_scan_target "any:image" "image" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_scan_target: always returns true for container type" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && validate_scan_target "any:container" "container" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_scan_target: validates sbom as file" {
	local test_file="${BATS_TEST_TMPDIR}/sbom.json"
	echo "{}" >"$test_file"
	run bash -c "source \"\$LIB_DIR/sbom/target.sh\" && validate_scan_target \"$test_file\" \"sbom\" && echo \"valid\""
	assert_success
	assert_output "valid"
}

@test "validate_scan_target: returns false for invalid target type" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && validate_scan_target "/path" "invalid" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

# =============================================================================
# describe_target_type tests
# =============================================================================

@test "describe_target_type: returns 'directory' for dir" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && describe_target_type "dir"'
	assert_success
	assert_output "directory"
}

@test "describe_target_type: returns 'directory' for directory" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && describe_target_type "directory"'
	assert_success
	assert_output "directory"
}

@test "describe_target_type: returns 'container image' for image" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && describe_target_type "image"'
	assert_success
	assert_output "container image"
}

@test "describe_target_type: returns 'container image' for container" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && describe_target_type "container"'
	assert_success
	assert_output "container image"
}

@test "describe_target_type: returns 'file' for file" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && describe_target_type "file"'
	assert_success
	assert_output "file"
}

@test "describe_target_type: returns 'SBOM file' for sbom" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && describe_target_type "sbom"'
	assert_success
	assert_output "SBOM file"
}

@test "describe_target_type: returns 'unknown' for invalid type" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && describe_target_type "invalid"'
	assert_success
	assert_output "unknown"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "target.sh: exports resolve_scan_target function" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && bash -c "resolve_scan_target /path dir"'
	assert_success
	assert_output "dir:/path"
}

@test "target.sh: exports validate_scan_target function" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && bash -c "validate_scan_target any image && echo ok"'
	assert_success
	assert_output "ok"
}

@test "target.sh: exports describe_target_type function" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && bash -c "describe_target_type dir"'
	assert_success
	assert_output "directory"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "target.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/sbom/target.sh"
		source "$LIB_DIR/sbom/target.sh"
		source "$LIB_DIR/sbom/target.sh"
		resolve_scan_target "/test" "dir"
	'
	assert_success
	assert_output "dir:/test"
}

@test "target.sh: sets _LGTM_CI_SBOM_TARGET_LOADED guard" {
	run bash -c 'source "$LIB_DIR/sbom/target.sh" && echo "${_LGTM_CI_SBOM_TARGET_LOADED}"'
	assert_success
	assert_output "1"
}
