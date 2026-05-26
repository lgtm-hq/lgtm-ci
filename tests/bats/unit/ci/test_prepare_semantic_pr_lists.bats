#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_github_env
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/prepare-semantic-pr-lists.sh"
}

teardown() {
	teardown_github_env
}

@test "prepare-semantic-pr-lists: uses built-in default when types input empty" {
	TYPES_INPUT="" SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	types="$(get_github_output types)"
	[[ "$types" == $'feat\nfix\ndocs\nstyle\nrefactor\nperf\ntest\nbuild\nci\nchore\nrevert' ]]
}

@test "prepare-semantic-pr-lists: normalizes comma-separated types" {
	TYPES_INPUT="feat,fix,ci" SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	types="$(get_github_output types)"
	[[ "$types" == $'feat\nfix\nci' ]]
}

@test "prepare-semantic-pr-lists: preserves newline-delimited types" {
	TYPES_INPUT=$'feat\nfix' SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	types="$(get_github_output types)"
	[[ "$types" == $'feat\nfix' ]]
}

@test "prepare-semantic-pr-lists: normalizes comma-separated scopes" {
	TYPES_INPUT="" SCOPES_INPUT="ci,deps" run bash "$SCRIPT"
	assert_success
	scopes="$(get_github_output scopes)"
	[[ "$scopes" == $'ci\ndeps' ]]
}
