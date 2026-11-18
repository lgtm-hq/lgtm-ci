#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/export-action-scripts-dir.sh (#1624)

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/export-action-scripts-dir.sh"

setup() {
	setup_github_env
}

teardown() {
	teardown_github_env
}

@test "export-action-scripts-dir.sh: exports the scripts/ three levels above the action" {
	local root="${BATS_TEST_TMPDIR}/tooling"
	mkdir -p "${root}/scripts" "${root}/.github/actions/example"
	local expected
	expected="$(cd "${root}/scripts" && pwd)"

	run env GITHUB_ACTION_PATH="${root}/.github/actions/example" bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_ENV"
	assert_output "SCRIPTS_DIR=${expected}"
}

@test "export-action-scripts-dir.sh: never asks git, so a nested checkout keeps its own scripts/" {
	# The workspace is a git repository; the action's tree is not its toplevel.
	local workspace="${BATS_TEST_TMPDIR}/workspace"
	local root="${workspace}/.lgtm-ci-tooling"
	mkdir -p "${workspace}/scripts" "${root}/scripts" "${root}/.github/actions/example"
	git -C "$workspace" init --quiet

	run env GITHUB_ACTION_PATH="${root}/.github/actions/example" bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_ENV"
	assert_output "SCRIPTS_DIR=$(cd "${root}/scripts" && pwd)"
}

@test "export-action-scripts-dir.sh: fails when the scripts/ directory is missing" {
	mkdir -p "${BATS_TEST_TMPDIR}/bare/.github/actions/example"

	run env GITHUB_ACTION_PATH="${BATS_TEST_TMPDIR}/bare/.github/actions/example" bash "$SCRIPT"
	assert_failure
	run cat "$GITHUB_ENV"
	assert_output ""
}

@test "export-action-scripts-dir.sh: fails without GITHUB_ACTION_PATH" {
	run env -u GITHUB_ACTION_PATH bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_ACTION_PATH is required"
}

@test "export-action-scripts-dir.sh: every composite that sets SCRIPTS_DIR calls it" {
	local inline
	inline="$(grep -rlF 'SCRIPTS_DIR="$(cd' "${PROJECT_ROOT}/.github/actions" || true)"
	assert_equal "$inline" ""
	run grep -rlF 'scripts/ci/actions/export-action-scripts-dir.sh"' "${PROJECT_ROOT}/.github/actions"
	assert_success
	assert_equal "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" "35"
}
