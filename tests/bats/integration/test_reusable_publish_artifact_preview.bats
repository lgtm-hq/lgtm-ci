#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-publish-artifact-preview workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-publish-artifact-preview.yml"

@test "reusable-publish-artifact-preview: workflow file exists" {
	[[ -f "$WORKFLOW" ]]
}

@test "reusable-publish-artifact-preview: declares required preview inputs" {
	run grep -F 'artifact-name:' "$WORKFLOW"
	assert_success
	run grep -F 'artifact-url:' "$WORKFLOW"
	assert_success
	run grep -F 'marker:' "$WORKFLOW"
	assert_success
	run grep -F 'summary:' "$WORKFLOW"
	assert_success
	run grep -F 'summary-file:' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-artifact-preview: exposes #393 contract inputs" {
	for input in tooling-ref egress-policy egress-preset allowed-endpoints \
		allowed-endpoints-mode runner-image timeout-minutes job-name; do
		run grep -F "${input}:" "$WORKFLOW"
		assert_success
	done
}

@test "reusable-publish-artifact-preview: egress-preset defaults to github-minimal" {
	run grep -F 'default: "github-minimal"' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-artifact-preview: job grants read/write PR permissions" {
	run grep -F 'contents: read' "$WORKFLOW"
	assert_success
	run grep -F 'pull-requests: write' "$WORKFLOW"
	assert_success
	run grep -F 'contents: write' "$WORKFLOW"
	assert_failure
}

@test "reusable-publish-artifact-preview: job uses static name and runner-image" {
	run grep -F 'name: ${{ inputs.job-name }}' "$WORKFLOW"
	assert_success
	run grep -F 'runs-on: ${{ inputs.runner-image }}' "$WORKFLOW"
	assert_success
	run grep -F 'timeout-minutes: ${{ inputs.timeout-minutes }}' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-artifact-preview: composes body via tooling script" {
	run grep -F 'compose-artifact-preview-comment.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-artifact-preview: reuses post-pr-comment with delete-on-empty" {
	run grep -F '.github/actions/post-pr-comment' "$WORKFLOW"
	assert_success
	run grep -F 'delete-on-empty: "true"' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-artifact-preview: sparse-checkout includes scripts/ci" {
	run grep -F 'scripts/ci/' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-artifact-preview: preserves egress checkout order" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" "publish-artifact-preview"
	assert_success
}

@test "reusable-publish-artifact-preview: passes runner contract validator" {
	run bash "${PROJECT_ROOT}/scripts/ci/quality/validate-runner-contract.sh"
	assert_success
}

@test "reusable-publish-artifact-preview: passes tooling sparse-checkout validator" {
	run bash "${PROJECT_ROOT}/scripts/ci/quality/validate-tooling-sparse-checkout.sh"
	assert_success
}

@test "reusable-publish-artifact-preview: passes static job names validator" {
	run bash "${PROJECT_ROOT}/scripts/ci/quality/validate-static-job-names.sh"
	assert_success
}
