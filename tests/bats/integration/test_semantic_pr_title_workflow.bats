#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for lgtm-ci semantic-pr-title caller workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/semantic-pr-title.yml"

@test "semantic-pr-title: calls local reusable workflow" {
	run grep -F 'uses: ./.github/workflows/reusable-semantic-pr-title.yml' "$WORKFLOW"
	assert_success
}

@test "semantic-pr-title: grants pull-requests write for failure comments" {
	run grep -E '^[[:space:]]+pull-requests: write$' "$WORKFLOW"
	assert_success
}

@test "semantic-pr-title: lets the reusable resolve its own tooling (#995)" {
	# A local reusable call resolves job.workflow_sha to this commit; passing
	# tooling-ref would only trigger the deprecation warning.
	run grep -F 'tooling-ref:' "$WORKFLOW"
	assert_failure
}
