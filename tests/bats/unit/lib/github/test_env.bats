#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/github/env.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
	teardown_github_env
}

# =============================================================================
# is_ci tests
# =============================================================================

@test "is_ci: returns true when CI=true" {
	run bash -c 'export CI=true; source "$LIB_DIR/github/env.sh" && is_ci'
	assert_success
}

@test "is_ci: returns true when GITHUB_ACTIONS=true" {
	run bash -c 'export GITHUB_ACTIONS=true; source "$LIB_DIR/github/env.sh" && is_ci'
	assert_success
}

@test "is_ci: returns false when neither CI nor GITHUB_ACTIONS set" {
	run bash -c 'unset CI GITHUB_ACTIONS; source "$LIB_DIR/github/env.sh" && is_ci'
	assert_failure
}

@test "is_ci: returns true with empty CI but GITHUB_ACTIONS set" {
	run bash -c 'export CI="" GITHUB_ACTIONS=true; source "$LIB_DIR/github/env.sh" && is_ci'
	assert_success
}

# =============================================================================
# is_github_actions tests
# =============================================================================

@test "is_github_actions: returns true when GITHUB_ACTIONS=true" {
	run bash -c 'export GITHUB_ACTIONS=true; source "$LIB_DIR/github/env.sh" && is_github_actions'
	assert_success
}

@test "is_github_actions: returns false when GITHUB_ACTIONS not set" {
	run bash -c 'unset GITHUB_ACTIONS; source "$LIB_DIR/github/env.sh" && is_github_actions'
	assert_failure
}

@test "is_github_actions: returns false when only CI set (not GITHUB_ACTIONS)" {
	run bash -c 'export CI=true; unset GITHUB_ACTIONS; source "$LIB_DIR/github/env.sh" && is_github_actions'
	assert_failure
}

# =============================================================================
# is_pr_context tests
# =============================================================================

@test "is_pr_context: returns true for pull_request event" {
	run bash -c 'export GITHUB_EVENT_NAME=pull_request; source "$LIB_DIR/github/env.sh" && is_pr_context'
	assert_success
}

@test "is_pr_context: returns true for pull_request_target event" {
	run bash -c 'export GITHUB_EVENT_NAME=pull_request_target; source "$LIB_DIR/github/env.sh" && is_pr_context'
	assert_success
}

@test "is_pr_context: returns false for push event" {
	run bash -c 'export GITHUB_EVENT_NAME=push; source "$LIB_DIR/github/env.sh" && is_pr_context'
	assert_failure
}

@test "is_pr_context: returns false for workflow_dispatch event" {
	run bash -c 'export GITHUB_EVENT_NAME=workflow_dispatch; source "$LIB_DIR/github/env.sh" && is_pr_context'
	assert_failure
}

@test "is_pr_context: returns false when GITHUB_EVENT_NAME not set" {
	run bash -c 'unset GITHUB_EVENT_NAME; source "$LIB_DIR/github/env.sh" && is_pr_context'
	assert_failure
}

# =============================================================================
# is_default_branch tests
# =============================================================================

@test "is_default_branch: returns true when on main (from GITHUB_REF_NAME)" {
	run bash -c '
		export GITHUB_REF_NAME=main
		export GITHUB_DEFAULT_BRANCH=main
		source "$LIB_DIR/github/env.sh" && is_default_branch
	'
	assert_success
}

@test "is_default_branch: returns true when on master (custom default)" {
	run bash -c '
		export GITHUB_REF_NAME=master
		export GITHUB_DEFAULT_BRANCH=master
		source "$LIB_DIR/github/env.sh" && is_default_branch
	'
	assert_success
}

@test "is_default_branch: returns false when on feature branch" {
	run bash -c '
		export GITHUB_REF_NAME=feature/new-thing
		export GITHUB_DEFAULT_BRANCH=main
		source "$LIB_DIR/github/env.sh" && is_default_branch
	'
	assert_failure
}

@test "is_default_branch: uses GITHUB_REF when GITHUB_REF_NAME not set" {
	run bash -c '
		unset GITHUB_REF_NAME
		export GITHUB_REF=refs/heads/main
		export GITHUB_DEFAULT_BRANCH=main
		source "$LIB_DIR/github/env.sh" && is_default_branch
	'
	assert_success
}

@test "is_default_branch: strips refs/heads/ prefix from GITHUB_REF" {
	run bash -c '
		unset GITHUB_REF_NAME
		export GITHUB_REF=refs/heads/develop
		export GITHUB_DEFAULT_BRANCH=develop
		source "$LIB_DIR/github/env.sh" && is_default_branch
	'
	assert_success
}

@test "is_default_branch: defaults to main when GITHUB_DEFAULT_BRANCH not set" {
	run bash -c '
		export GITHUB_REF_NAME=main
		unset GITHUB_DEFAULT_BRANCH
		source "$LIB_DIR/github/env.sh" && is_default_branch
	'
	assert_success
}

# =============================================================================
# Function export tests
# =============================================================================

@test "github/env.sh: exports is_ci function" {
	run bash -c 'source "$LIB_DIR/github/env.sh" && bash -c "type is_ci"'
	assert_success
}

@test "github/env.sh: exports is_github_actions function" {
	run bash -c 'source "$LIB_DIR/github/env.sh" && bash -c "type is_github_actions"'
	assert_success
}

@test "github/env.sh: exports is_pr_context function" {
	run bash -c 'source "$LIB_DIR/github/env.sh" && bash -c "type is_pr_context"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "github/env.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/github/env.sh"
		source "$LIB_DIR/github/env.sh"
		export CI=true
		is_ci
	'
	assert_success
}

@test "github/env.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/github/env.sh" && echo "${_LGTM_CI_GITHUB_ENV_LOADED}"'
	assert_success
	assert_output "1"
}
