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
	assert_github_output types $'feat\nfix\ndocs\nstyle\nrefactor\nperf\ntest\nbuild\nci\nchore\nrevert'
	run grep -E '^scopes(=|<<)' "$GITHUB_OUTPUT"
	assert_failure
}

@test "prepare-semantic-pr-lists: normalizes comma-separated types" {
	TYPES_INPUT="feat,fix,ci" SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	assert_github_output types $'feat\nfix\nci'
}

@test "prepare-semantic-pr-lists: trims whitespace around CSV entries" {
	TYPES_INPUT="feat, fix, docs" SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	assert_github_output types $'feat\nfix\ndocs'
}

@test "prepare-semantic-pr-lists: preserves newline-delimited types" {
	TYPES_INPUT=$'feat\nfix' SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	assert_github_output types $'feat\nfix'
}

@test "prepare-semantic-pr-lists: normalizes commas in mixed-format input" {
	TYPES_INPUT=$'feat,fix\n ci' SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	assert_github_output types $'feat\nfix\nci'
}

@test "prepare-semantic-pr-lists: normalizes comma-separated scopes" {
	TYPES_INPUT="" SCOPES_INPUT="ci,deps" run bash "$SCRIPT"
	assert_success
	assert_github_output scopes $'ci\ndeps'
}

@test "prepare-semantic-pr-lists: preserves delimiter when value contains EOF line" {
	TYPES_INPUT=$'feat\nEOF\nfix' SCOPES_INPUT="" run bash "$SCRIPT"
	assert_success
	assert_github_output types $'feat\nEOF\nfix'
}
