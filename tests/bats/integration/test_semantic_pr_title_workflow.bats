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

@test "semantic-pr-title: pins tooling to current commit" {
	run grep -F 'tooling-ref: ${{ github.sha }}' "$WORKFLOW"
	assert_success
}
