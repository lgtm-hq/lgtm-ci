#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for Cargo auto-tag inputs in reusable-release-auto-tag

load "../../helpers/common"

@test "reusable-release-auto-tag: defines cargo version-source inputs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run grep -F "version-source:" "$workflow"
	assert_success
	run grep -F "version-file:" "$workflow"
	assert_success
	run grep -F "skip-if-unchanged:" "$workflow"
	assert_success
}

@test "reusable-release-auto-tag: wires cargo version resolution scripts" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run grep -F "resolve-auto-tag-version.sh" "$workflow"
	assert_success
	run grep -F "detect-previous-tag-version.sh" "$workflow"
	assert_success
	run grep -F "check-version-unchanged.sh" "$workflow"
	assert_success
}

@test "reusable-release-auto-tag: guards release commit before version resolve" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run awk '
		/- name: Guard release commit/ { saw_guard = 1 }
		saw_guard && /- name: Resolve version/ { saw_resolve = 1; exit }
		END { exit !saw_resolve }
	' "$workflow"
	assert_success
}
