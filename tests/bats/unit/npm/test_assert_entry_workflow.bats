#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/npm/assert-entry-workflow.sh (#965)

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/npm/assert-entry-workflow.sh"

setup() {
	setup_temp_dir
	save_path
	export PROJECT_ROOT
	export SCRIPT
	# The shape GITHUB_WORKFLOW_REF actually has on a tag run:
	# owner/repository/.github/workflows/file.yml@ref
	export ENTRY_WORKFLOW_REF="lgtm-hq/lgtm-ci/.github/workflows/publish-npm-set.yml@refs/tags/v1.2.3"
}

teardown() {
	restore_path
	teardown_temp_dir
}

@test "assert-entry-workflow: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}

@test "assert-entry-workflow: empty allowlist skips with a warning on a dry-run" {
	unset ALLOWED_ENTRY_WORKFLOWS
	export LIVE=0

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "skipping the npm entry-workflow guard for this dry-run"
}

@test "assert-entry-workflow: empty allowlist fails closed on a live publish" {
	unset ALLOWED_ENTRY_WORKFLOWS
	export LIVE=1

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "live npm publish requires the 'entry-workflows' input"
	assert_output --partial "Nothing was published"
}

@test "assert-entry-workflow: allows the allowlisted entry workflow" {
	export ALLOWED_ENTRY_WORKFLOWS=".github/workflows/publish-npm-set.yml"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "allowlisted"
}

@test "assert-entry-workflow: strips the owner/repo prefix and @ref suffix on a tag run" {
	export ALLOWED_ENTRY_WORKFLOWS=".github/workflows/publish-npm-set.yml"
	export ENTRY_WORKFLOW_REF="lgtm-hq/lgtm-ci/.github/workflows/publish-npm-set.yml@refs/tags/v1.2.3"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Entry workflow '.github/workflows/publish-npm-set.yml' is allowlisted"
}

@test "assert-entry-workflow: handles branch runs and a bare path" {
	export ALLOWED_ENTRY_WORKFLOWS=".github/workflows/publish-npm-set.yml"
	export ENTRY_WORKFLOW_REF="lgtm-hq/lgtm-ci/.github/workflows/publish-npm-set.yml@refs/heads/main"

	run bash "$SCRIPT"
	assert_success
	export ENTRY_WORKFLOW_REF=".github/workflows/publish-npm-set.yml"
	run bash "$SCRIPT"
	assert_success
}

@test "assert-entry-workflow: does not let the repository prefix satisfy the allowlist" {
	# Only the workflow path is compared; a repo-qualified allowlist entry
	# never matches, so a consumer cannot accidentally allow by repo name.
	export ALLOWED_ENTRY_WORKFLOWS="lgtm-hq/lgtm-ci/.github/workflows/publish-npm-set.yml"

	run bash "$SCRIPT"
	assert_failure
}

@test "assert-entry-workflow: rejects an entry outside the allowlist" {
	export ALLOWED_ENTRY_WORKFLOWS=".github/workflows/other-entry.yml"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not in the npm trusted-publishing allowlist"
	assert_output --partial "trusted-publisher registration"
}

@test "assert-entry-workflow: supports a comma-separated allowlist" {
	export ALLOWED_ENTRY_WORKFLOWS=".github/workflows/ci.yml, .github/workflows/publish-npm-set.yml"

	run bash "$SCRIPT"
	assert_success
}

@test "assert-entry-workflow: supports a newline-separated allowlist" {
	export ALLOWED_ENTRY_WORKFLOWS=$'.github/workflows/ci.yml\n.github/workflows/publish-npm-set.yml'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "allowlisted"
}

@test "assert-entry-workflow: fails when the entry ref cannot be determined" {
	export ALLOWED_ENTRY_WORKFLOWS=".github/workflows/publish-npm-set.yml"
	unset ENTRY_WORKFLOW_REF
	unset GITHUB_WORKFLOW_REF

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "cannot determine the entry workflow"
}
