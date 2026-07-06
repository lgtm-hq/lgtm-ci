#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-main-failure-notifier.yml

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-main-failure-notifier.yml"

@test "main-failure-notifier: requires a workflow-key input" {
	run awk '
		/^      workflow-key:/ { in_input = 1 }
		in_input && /required: true/ { found = 1; exit }
		in_input && /^      [a-z-]+:/ && $0 !~ /workflow-key:/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "main-failure-notifier: notify job grants issues write and reads actions" {
	run grep -F "issues: write" "$WORKFLOW"
	assert_success
	run grep -F "actions: read" "$WORKFLOW"
	assert_success
}

@test "main-failure-notifier: hardens egress before reporting" {
	run grep -F "harden-runner" "$WORKFLOW"
	assert_success
	run grep -F "resolve-egress-allowlist" "$WORKFLOW"
	assert_success
}

@test "main-failure-notifier: delegates to the parameterized failure reporter" {
	run grep -F "report-release-failure.sh" "$WORKFLOW"
	assert_success
	run grep -F "WORKFLOW_KEY: \${{ inputs.workflow-key }}" "$WORKFLOW"
	assert_success
	run grep -F "FAILURE_MARKER_PREFIX: main-workflow-failure" "$WORKFLOW"
	assert_success
	run grep -F "notify_failure" "$WORKFLOW"
	assert_success
	run grep -F "write_trigger_summary" "$WORKFLOW"
	assert_success
}

@test "main-failure-notifier: tooling checkout includes failure reporter script" {
	run grep -F "sparse-checkout" "$WORKFLOW"
	assert_success
	run grep -F "scripts/ci/" "$WORKFLOW"
	assert_success
}
