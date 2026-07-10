#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/write-release-summary.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/write-release-summary.sh"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "write-release-summary.sh: fails without VERSION" {
	run env -u VERSION bash "$SCRIPT"
	assert_failure
	assert_output --partial "VERSION is required"
}

@test "write-release-summary.sh: dry-run writes version and bump preview" {
	run env \
		SUMMARY_TYPE=dry-run \
		VERSION=1.2.3 \
		TAG_PREFIX=v \
		BUMP_TYPE=minor \
		CHANGELOG='### Added\n- feature' \
		bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "## Dry Run Summary"
	assert_output --partial "**Version:** 1.2.3"
	assert_output --partial "**Tag:** v1.2.3"
	assert_output --partial "**Bump type:** minor"
	assert_output --partial "### Changelog Preview"
}

@test "write-release-summary.sh: release with URL writes Release Created" {
	run env \
		SUMMARY_TYPE=release \
		VERSION=2.0.0 \
		TAG_NAME=v2.0.0 \
		RELEASE_URL=https://github.com/org/repo/releases/tag/v2.0.0 \
		bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "## Release Created"
	assert_output --partial "**Version:** 2.0.0"
	assert_output --partial "**Tag:** v2.0.0"
	assert_output --partial "**Release:** https://github.com/org/repo/releases/tag/v2.0.0"
}

@test "write-release-summary.sh: release without URL writes Release Tag Created" {
	run env \
		SUMMARY_TYPE=release \
		VERSION=2.0.0 \
		TAG_NAME=v2.0.0 \
		RELEASE_URL= \
		bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "## Release Tag Created"
	refute_output --partial "**Release:**"
}

@test "write-release-summary.sh: rejects unknown SUMMARY_TYPE" {
	run env SUMMARY_TYPE=bogus VERSION=1.0.0 bash "$SCRIPT"
	assert_failure
	assert_output --partial "Unknown summary type: bogus"
}
