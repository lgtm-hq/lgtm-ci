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

@test "semantic-pr-title: declares no concurrency group that could cancel runs" {
	# A bot push followed by a PR body edit fires synchronize then edited. A
	# per-PR group cancelled the in-progress run (cancel-in-progress: true) or
	# the superseded pending run (cancel-in-progress: false), leaving a
	# cancelled check on the head commit.
	run grep -E '^[[:space:]]*concurrency:' "$WORKFLOW"
	assert_failure
}

@test "semantic-pr-title: still runs on every title-affecting event" {
	run grep -Fx '    types: [opened, edited, synchronize, reopened, ready_for_review]' "$WORKFLOW"
	assert_success
	run grep -Fx '  merge_group:' "$WORKFLOW"
	assert_success
}

@test "semantic-pr-title: leaves max-length unset so overlapping runs agree" {
	# The length step reads the title from the event payload; only the
	# semantic step re-reads the current title. Without a concurrency group a
	# stale run could post a length failure for an already-fixed title.
	run grep -F 'max-length:' "$WORKFLOW"
	assert_failure
}
