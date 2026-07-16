#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/resolve-scripts-dir.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/resolve-scripts-dir.sh"

setup() {
	setup_github_env
}

teardown() {
	teardown_github_env
}

@test "resolve-scripts-dir.sh: derives SCRIPTS_DIR from action path layout" {
	local action_dir="${BATS_TEST_TMPDIR}/repo/.github/actions/example"
	mkdir -p "$action_dir"

	run env GITHUB_ACTION_PATH="$action_dir" bash "$SCRIPT"
	assert_success
	run grep -q "^SCRIPTS_DIR=${BATS_TEST_TMPDIR}/repo/scripts\$" "$GITHUB_ENV"
	assert_success
}

@test "resolve-scripts-dir.sh: prefers git toplevel when available" {
	local repo="${BATS_TEST_TMPDIR}/git-repo"
	local action_dir="${repo}/.github/actions/example"
	mkdir -p "${repo}/scripts" "$action_dir"
	git -C "$repo" init >/dev/null
	local expected
	expected="$(cd "$action_dir" && git rev-parse --show-toplevel)/scripts"

	run env GITHUB_ACTION_PATH="$action_dir" bash "$SCRIPT"
	assert_success
	run grep -q "^SCRIPTS_DIR=${expected}\$" "$GITHUB_ENV"
	assert_success
}

@test "resolve-scripts-dir.sh: normalizes Windows-style backslashes" {
	local repo="${BATS_TEST_TMPDIR}/win-repo"
	local action_dir="${repo}/.github/actions/example"
	mkdir -p "$action_dir"
	local win_path="${action_dir//\//\\}"

	run env GITHUB_ACTION_PATH="$win_path" bash "$SCRIPT"
	assert_success
	run grep -q "^SCRIPTS_DIR=${repo}/scripts\$" "$GITHUB_ENV"
	assert_success
}

@test "resolve-scripts-dir.sh: fails without GITHUB_ACTION_PATH" {
	run env -u GITHUB_ACTION_PATH bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_ACTION_PATH is required"
}
