#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/conventional.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_conventional_commit tests - basic parsing
# =============================================================================

@test "parse_conventional_commit: parses feat commit" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "feat: add new feature"
		echo "type=$CC_TYPE"
		echo "desc=$CC_DESCRIPTION"
	'
	assert_success
	assert_line "type=feat"
	assert_line "desc=add new feature"
}

@test "parse_conventional_commit: parses fix commit" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "fix: resolve bug"
		echo "type=$CC_TYPE"
		echo "desc=$CC_DESCRIPTION"
	'
	assert_success
	assert_line "type=fix"
	assert_line "desc=resolve bug"
}

@test "parse_conventional_commit: parses commit with scope" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "feat(api): add new endpoint"
		echo "type=$CC_TYPE"
		echo "scope=$CC_SCOPE"
		echo "desc=$CC_DESCRIPTION"
	'
	assert_success
	assert_line "type=feat"
	assert_line "scope=api"
	assert_line "desc=add new endpoint"
}

@test "parse_conventional_commit: parses breaking change with !" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "feat!: breaking api change"
		echo "type=$CC_TYPE"
		echo "breaking=$CC_BREAKING"
		echo "desc=$CC_DESCRIPTION"
	'
	assert_success
	assert_line "type=feat"
	assert_line "breaking=!"
	assert_line "desc=breaking api change"
}

@test "parse_conventional_commit: parses breaking change with scope and !" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "feat(core)!: major refactor"
		echo "type=$CC_TYPE"
		echo "scope=$CC_SCOPE"
		echo "breaking=$CC_BREAKING"
	'
	assert_success
	assert_line "type=feat"
	assert_line "scope=core"
	assert_line "breaking=!"
}

@test "parse_conventional_commit: handles docs type" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "docs: update readme"
		echo "type=$CC_TYPE"
	'
	assert_success
	assert_line "type=docs"
}

@test "parse_conventional_commit: handles chore type" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "chore: update dependencies"
		echo "type=$CC_TYPE"
	'
	assert_success
	assert_line "type=chore"
}

@test "parse_conventional_commit: handles refactor type" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "refactor(utils): simplify logic"
		echo "type=$CC_TYPE"
		echo "scope=$CC_SCOPE"
	'
	assert_success
	assert_line "type=refactor"
	assert_line "scope=utils"
}

# =============================================================================
# parse_conventional_commit tests - edge cases and failures
# =============================================================================

@test "parse_conventional_commit: returns failure for non-conventional message" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "Update readme"
	'
	assert_failure
}

@test "parse_conventional_commit: returns failure for empty message" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit ""
	'
	assert_failure
}

@test "parse_conventional_commit: returns failure for message without colon" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "feat add something"
	'
	assert_failure
}

@test "parse_conventional_commit: handles description with special characters" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		parse_conventional_commit "fix: handle \$PATH and \"quotes\""
		echo "desc=$CC_DESCRIPTION"
	'
	assert_success
	assert_output --partial "handle"
}

# =============================================================================
# is_breaking_change tests
# =============================================================================

@test "is_breaking_change: detects ! indicator" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		is_breaking_change "feat!: breaking change"
	'
	assert_success
}

@test "is_breaking_change: detects ! with scope" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		is_breaking_change "feat(api)!: breaking change"
	'
	assert_success
}

@test "is_breaking_change: detects BREAKING CHANGE in body" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		is_breaking_change "feat: new thing

BREAKING CHANGE: old API removed"
	'
	assert_success
}

@test "is_breaking_change: detects BREAKING-CHANGE in body" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		is_breaking_change "feat: new thing

BREAKING-CHANGE: old API removed"
	'
	assert_success
}

@test "is_breaking_change: returns false for non-breaking commit" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		is_breaking_change "feat: add feature"
	'
	assert_failure
}

@test "is_breaking_change: returns false for fix commit" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		is_breaking_change "fix: resolve issue"
	'
	assert_failure
}

# =============================================================================
# get_bump_for_type tests
# =============================================================================

@test "get_bump_for_type: feat returns minor" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "feat"
	'
	assert_success
	assert_output "minor"
}

@test "get_bump_for_type: feature returns minor" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "feature"
	'
	assert_success
	assert_output "minor"
}

@test "get_bump_for_type: fix returns patch" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "fix"
	'
	assert_success
	assert_output "patch"
}

@test "get_bump_for_type: bugfix returns patch" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "bugfix"
	'
	assert_success
	assert_output "patch"
}

@test "get_bump_for_type: hotfix returns patch" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "hotfix"
	'
	assert_success
	assert_output "patch"
}

@test "get_bump_for_type: docs returns none" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "docs"
	'
	assert_success
	assert_output "none"
}

@test "get_bump_for_type: chore returns none" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "chore"
	'
	assert_success
	assert_output "none"
}

@test "get_bump_for_type: refactor returns none" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "refactor"
	'
	assert_success
	assert_output "none"
}

@test "get_bump_for_type: test returns none" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "test"
	'
	assert_success
	assert_output "none"
}

@test "get_bump_for_type: unknown type returns none" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type "random"
	'
	assert_success
	assert_output "none"
}

@test "get_bump_for_type: empty type returns none" {
	run bash -c '
		source "$LIB_DIR/release/conventional.sh"
		get_bump_for_type ""
	'
	assert_success
	assert_output "none"
}

# =============================================================================
# Guard and readonly tests
# =============================================================================

@test "release/conventional.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/release/conventional.sh" && echo "${_RELEASE_CONVENTIONAL_LOADED}"'
	assert_success
	assert_output "1"
}

@test "release/conventional.sh: CC_PATTERN is readonly" {
	run bash -c 'source "$LIB_DIR/release/conventional.sh" && CC_PATTERN="changed" 2>&1'
	assert_failure
	assert_output --partial "readonly"
}
