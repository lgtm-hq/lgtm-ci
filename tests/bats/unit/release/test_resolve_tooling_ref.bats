#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/resolve-tooling-ref.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/resolve-tooling-ref.sh"

setup() {
	setup_github_env
}

teardown() {
	teardown_github_env
}

@test "resolve-tooling-ref.sh: prefers explicit TOOLING_REF" {
	run env \
		TOOLING_REF="abc123" \
		GH_REPO="someone/else" \
		GH_SHA="deadbeef" \
		WORKFLOW_SHA="workflowsha" \
		bash "$SCRIPT"
	assert_success
	run grep -q '^ref=abc123$' "$GITHUB_OUTPUT"
	assert_success
}

@test "resolve-tooling-ref.sh: uses GH_SHA inside lgtm-ci" {
	run env \
		TOOLING_REF="" \
		GH_REPO="lgtm-hq/lgtm-ci" \
		GH_SHA="commitsha" \
		WORKFLOW_SHA="workflowsha" \
		bash "$SCRIPT"
	assert_success
	run grep -q '^ref=commitsha$' "$GITHUB_OUTPUT"
	assert_success
}

@test "resolve-tooling-ref.sh: falls back to WORKFLOW_SHA for consumers" {
	run env \
		TOOLING_REF="" \
		GH_REPO="acme/app" \
		GH_SHA="commitsha" \
		WORKFLOW_SHA="workflowsha" \
		bash "$SCRIPT"
	assert_success
	run grep -q '^ref=workflowsha$' "$GITHUB_OUTPUT"
	assert_success
}

@test "resolve-tooling-ref.sh: fails without WORKFLOW_SHA" {
	run env -u WORKFLOW_SHA \
		GH_REPO="acme/app" \
		GH_SHA="commitsha" \
		bash "$SCRIPT"
	assert_failure
	assert_output --partial "WORKFLOW_SHA is required"
}
