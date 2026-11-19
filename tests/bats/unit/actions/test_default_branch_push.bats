#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/default-branch-push.sh (#1659): a
#          case-sensitive, literal "push to the default branch" decision that
#          fails closed, for the cache save steps.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/default-branch-push.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	unset GITHUB_EVENT_NAME GITHUB_REF DEFAULT_BRANCH
}

teardown() {
	teardown_temp_dir
}

# Run the script with <event> <ref> <default branch> and print its output.
_decide() {
	GITHUB_EVENT_NAME="$1" GITHUB_REF="$2" DEFAULT_BRANCH="$3" bash "$SCRIPT"
}

_output_value() {
	grep '^default-branch-push=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

@test "default-branch-push: a push to the default branch is true" {
	run _decide push refs/heads/main main
	assert_success
	assert_output --partial "push to the default branch (refs/heads/main)"
	assert_equal "$(_output_value)" "true"
}

@test "default-branch-push: a push to a branch differing only in case is false" {
	run _decide push refs/heads/Main main
	assert_success
	assert_output --partial "the ref is 'refs/heads/Main', not refs/heads/main"
	assert_equal "$(_output_value)" "false"

	: >"$GITHUB_OUTPUT"
	run _decide push refs/heads/main Main
	assert_success
	assert_equal "$(_output_value)" "false"
}

@test "default-branch-push: a tag named like the default branch is false" {
	run _decide push refs/tags/main main
	assert_success
	assert_equal "$(_output_value)" "false"
}

@test "default-branch-push: an empty or unset default branch is false" {
	run _decide push refs/heads/ ""
	assert_success
	assert_output --partial "the default branch is unknown"
	assert_equal "$(_output_value)" "false"

	: >"$GITHUB_OUTPUT"
	run env -u DEFAULT_BRANCH GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main bash "$SCRIPT"
	assert_success
	assert_equal "$(_output_value)" "false"
}

@test "default-branch-push: any event other than push is false" {
	local event
	for event in pull_request pull_request_target merge_group schedule workflow_dispatch \
		workflow_call Push "push " ""; do
		: >"$GITHUB_OUTPUT"
		run _decide "$event" refs/heads/main main
		assert_success
		assert_equal "$(_output_value)" "false"
	done
}

@test "default-branch-push: special characters in a branch name compare literally" {
	# Glob characters must not act as a pattern.
	run _decide push refs/heads/release-1 'release-*'
	assert_success
	assert_equal "$(_output_value)" "false"
	: >"$GITHUB_OUTPUT"
	run _decide push refs/heads/feature/x '[f]eature/?'
	assert_success
	assert_equal "$(_output_value)" "false"

	# The same name, special characters and all, matches itself.
	: >"$GITHUB_OUTPUT"
	run _decide push 'refs/heads/feat/[x]*?$(id)' 'feat/[x]*?$(id)'
	assert_success
	assert_equal "$(_output_value)" "true"
	refute_output --partial "uid="

	: >"$GITHUB_OUTPUT"
	run _decide push 'refs/heads/héllo-wörld' 'héllo-wörld'
	assert_success
	assert_equal "$(_output_value)" "true"
}

@test "default-branch-push: a control character in the default branch is false" {
	run _decide push $'refs/heads/main\nx' $'main\nx'
	assert_success
	assert_output --partial "control character"
	assert_equal "$(_output_value)" "false"
}

@test "default-branch-push: a ref with a suffix or prefix is false" {
	run _decide push refs/heads/main-old main
	assert_success
	assert_equal "$(_output_value)" "false"
	: >"$GITHUB_OUTPUT"
	run _decide push refs/heads/x/main main
	assert_success
	assert_equal "$(_output_value)" "false"
	: >"$GITHUB_OUTPUT"
	run _decide push refs/pull/1/merge main
	assert_success
	assert_equal "$(_output_value)" "false"
}
