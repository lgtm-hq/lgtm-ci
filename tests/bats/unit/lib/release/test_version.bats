#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/version.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# validate_semver tests - basic versions
# =============================================================================

@test "validate_semver: accepts 1.0.0" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts 0.0.1" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "0.0.1" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts 10.20.30" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "10.20.30" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts v prefix" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "v1.2.3" && echo "valid"'
	assert_success
	assert_output "valid"
}

# =============================================================================
# validate_semver tests - prerelease versions
# =============================================================================

@test "validate_semver: accepts prerelease alpha" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0-alpha" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts prerelease alpha.1" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0-alpha.1" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts prerelease beta.2" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0-beta.2" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts prerelease rc.1" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "2.0.0-rc.1" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts complex prerelease" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0-alpha.1.beta.2" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts numeric prerelease" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0-0" && echo "valid"'
	assert_success
	assert_output "valid"
}

# =============================================================================
# validate_semver tests - build metadata
# =============================================================================

@test "validate_semver: accepts build metadata" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0+build" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts build metadata with numbers" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0+20230101" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_semver: accepts prerelease and build metadata" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.0-alpha.1+build.123" && echo "valid"'
	assert_success
	assert_output "valid"
}

# =============================================================================
# validate_semver tests - invalid versions
# =============================================================================

@test "validate_semver: rejects missing patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_semver: rejects missing minor and patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_semver: rejects leading zero in major" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "01.0.0" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_semver: rejects leading zero in minor" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.01.0" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_semver: rejects leading zero in patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "1.0.01" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_semver: rejects empty string" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_semver: rejects letters in version" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && validate_semver "a.b.c" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

# =============================================================================
# parse_version tests
# =============================================================================

@test "parse_version: sets MAJOR MINOR PATCH for 1.2.3" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && parse_version "1.2.3" && echo "$MAJOR.$MINOR.$PATCH"'
	assert_success
	assert_output "1.2.3"
}

@test "parse_version: strips v prefix" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && parse_version "v1.2.3" && echo "$MAJOR.$MINOR.$PATCH"'
	assert_success
	assert_output "1.2.3"
}

@test "parse_version: handles large numbers" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && parse_version "100.200.300" && echo "$MAJOR.$MINOR.$PATCH"'
	assert_success
	assert_output "100.200.300"
}

@test "parse_version: strips prerelease" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && parse_version "1.2.3-alpha.1" && echo "$MAJOR.$MINOR.$PATCH"'
	assert_success
	assert_output "1.2.3"
}

@test "parse_version: strips build metadata" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && parse_version "1.2.3+build" && echo "$MAJOR.$MINOR.$PATCH"'
	assert_success
	assert_output "1.2.3"
}

@test "parse_version: returns 1 for invalid version" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && parse_version "invalid" || echo "failed"'
	assert_success
	assert_output "failed"
}

# =============================================================================
# bump_version tests - patch
# =============================================================================

@test "bump_version: patch bump 1.0.0 -> 1.0.1" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.0.0" "patch"'
	assert_success
	assert_output "1.0.1"
}

@test "bump_version: patch bump 1.2.3 -> 1.2.4" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.2.3" "patch"'
	assert_success
	assert_output "1.2.4"
}

@test "bump_version: patch is default" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.0.0"'
	assert_success
	assert_output "1.0.1"
}

# =============================================================================
# bump_version tests - minor
# =============================================================================

@test "bump_version: minor bump 1.0.0 -> 1.1.0" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.0.0" "minor"'
	assert_success
	assert_output "1.1.0"
}

@test "bump_version: minor bump resets patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.2.3" "minor"'
	assert_success
	assert_output "1.3.0"
}

# =============================================================================
# bump_version tests - major
# =============================================================================

@test "bump_version: major bump 1.0.0 -> 2.0.0" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.0.0" "major"'
	assert_success
	assert_output "2.0.0"
}

@test "bump_version: major bump resets minor and patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.2.3" "major"'
	assert_success
	assert_output "2.0.0"
}

# =============================================================================
# bump_version tests - edge cases
# =============================================================================

@test "bump_version: handles v prefix" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "v1.0.0" "patch"'
	assert_success
	assert_output "1.0.1"
}

@test "bump_version: returns error for invalid bump type" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "1.0.0" "invalid" 2>&1'
	assert_failure
	assert_output --partial "Invalid bump type"
}

@test "bump_version: returns error for invalid version" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && bump_version "invalid" "patch" 2>&1'
	assert_failure
	assert_output --partial "Invalid version"
}

# =============================================================================
# compare_versions tests - equal
# =============================================================================

@test "compare_versions: returns 0 for equal versions" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0" "1.0.0"; echo $?'
	assert_success
	assert_output "0"
}

@test "compare_versions: handles v prefix" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "v1.0.0" "1.0.0"; echo $?'
	assert_success
	assert_output "0"
}

# =============================================================================
# compare_versions tests - greater
# =============================================================================

@test "compare_versions: returns 1 when v1 > v2 (major)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "2.0.0" "1.0.0"; echo $?'
	assert_success
	assert_output "1"
}

@test "compare_versions: returns 1 when v1 > v2 (minor)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.2.0" "1.1.0"; echo $?'
	assert_success
	assert_output "1"
}

@test "compare_versions: returns 1 when v1 > v2 (patch)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.2" "1.0.1"; echo $?'
	assert_success
	assert_output "1"
}

# =============================================================================
# compare_versions tests - less
# =============================================================================

@test "compare_versions: returns 2 when v1 < v2 (major)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0" "2.0.0"; echo $?'
	assert_success
	assert_output "2"
}

@test "compare_versions: returns 2 when v1 < v2 (minor)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.1.0" "1.2.0"; echo $?'
	assert_success
	assert_output "2"
}

@test "compare_versions: returns 2 when v1 < v2 (patch)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.1" "1.0.2"; echo $?'
	assert_success
	assert_output "2"
}

# =============================================================================
# compare_versions tests - prerelease
# =============================================================================

@test "compare_versions: release > prerelease" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0" "1.0.0-alpha"; echo $?'
	assert_success
	assert_output "1"
}

@test "compare_versions: prerelease < release" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0-alpha" "1.0.0"; echo $?'
	assert_success
	assert_output "2"
}

@test "compare_versions: alpha < beta" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0-alpha" "1.0.0-beta"; echo $?'
	assert_success
	assert_output "2"
}

@test "compare_versions: alpha.1 < alpha.2" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0-alpha.1" "1.0.0-alpha.2"; echo $?'
	assert_success
	assert_output "2"
}

@test "compare_versions: numeric prerelease < alphanumeric" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0-1" "1.0.0-alpha"; echo $?'
	assert_success
	assert_output "2"
}

@test "compare_versions: ignores build metadata" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && compare_versions "1.0.0+build1" "1.0.0+build2"; echo $?'
	assert_success
	assert_output "0"
}

# =============================================================================
# max_bump tests
# =============================================================================

@test "max_bump: patch vs minor -> minor" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "patch" "minor"'
	assert_success
	assert_output "minor"
}

@test "max_bump: minor vs patch -> minor" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "minor" "patch"'
	assert_success
	assert_output "minor"
}

@test "max_bump: patch vs major -> major" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "patch" "major"'
	assert_success
	assert_output "major"
}

@test "max_bump: major vs patch -> major" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "major" "patch"'
	assert_success
	assert_output "major"
}

@test "max_bump: minor vs major -> major" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "minor" "major"'
	assert_success
	assert_output "major"
}

@test "max_bump: major vs minor -> major" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "major" "minor"'
	assert_success
	assert_output "major"
}

@test "max_bump: same types return same" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "minor" "minor"'
	assert_success
	assert_output "minor"
}

@test "max_bump: defaults to patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && max_bump "" ""'
	assert_success
	assert_output "patch"
}

# =============================================================================
# clamp_bump tests
# =============================================================================

@test "clamp_bump: major clamped to minor -> minor" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && clamp_bump "major" "minor"'
	assert_success
	assert_output "minor"
}

@test "clamp_bump: major clamped to patch -> patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && clamp_bump "major" "patch"'
	assert_success
	assert_output "patch"
}

@test "clamp_bump: minor clamped to patch -> patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && clamp_bump "minor" "patch"'
	assert_success
	assert_output "patch"
}

@test "clamp_bump: minor clamped to major -> minor (unchanged)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && clamp_bump "minor" "major"'
	assert_success
	assert_output "minor"
}

@test "clamp_bump: patch clamped to major -> patch (unchanged)" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && clamp_bump "patch" "major"'
	assert_success
	assert_output "patch"
}

@test "clamp_bump: defaults to patch" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && clamp_bump "" ""'
	assert_success
	assert_output "patch"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "version.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/release/version.sh"
		source "$LIB_DIR/release/version.sh"
		source "$LIB_DIR/release/version.sh"
		validate_semver "1.0.0" && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "version.sh: sets _RELEASE_VERSION_LOADED guard" {
	run bash -c 'source "$LIB_DIR/release/version.sh" && echo "${_RELEASE_VERSION_LOADED}"'
	assert_success
	assert_output "1"
}
