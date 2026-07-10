#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/write-version-pr-summary.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/write-version-pr-summary.sh"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "write-version-pr-summary.sh: skips when last commit is a release" {
	run env IS_RELEASE=true bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "## Version PR Summary"
	assert_output --partial "Skipped: last commit is a release commit"
}

@test "write-version-pr-summary.sh: skips when version PR already exists" {
	run env IS_RELEASE=false PR_EXISTS=true bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: version PR already exists"
}

@test "write-version-pr-summary.sh: skips when no releasable commits" {
	run env IS_RELEASE=false PR_EXISTS=false RELEASE_NEEDED=false bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Skipped: no releasable commits found"
}

@test "write-version-pr-summary.sh: writes created PR details" {
	run env \
		IS_RELEASE=false \
		PR_EXISTS=false \
		RELEASE_NEEDED=true \
		NEXT_VERSION=1.4.0 \
		BUMP_TYPE=minor \
		PR_URL=https://github.com/org/repo/pull/99 \
		PR_OP=created \
		ECOSYSTEMS=python,npm \
		bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "**Version:** 1.4.0"
	assert_output --partial "**Bump type:** minor"
	assert_output --partial "**PR:** https://github.com/org/repo/pull/99"
	assert_output --partial "**Operation:** created"
	assert_output --partial "**Ecosystems:** python,npm"
}
