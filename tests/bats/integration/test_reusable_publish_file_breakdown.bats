#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-publish-file-breakdown.yml (#73)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-publish-file-breakdown.yml"

@test "publish-file-breakdown: satisfies runner contract validator" {
	run "${PROJECT_ROOT}/scripts/ci/quality/validate-runner-contract.sh"
	assert_success
}

@test "publish-file-breakdown: satisfies static job name validator" {
	run "${PROJECT_ROOT}/scripts/ci/quality/validate-static-job-names.sh"
	assert_success
}

@test "publish-file-breakdown: satisfies tooling sparse-checkout validator" {
	run "${PROJECT_ROOT}/scripts/ci/quality/validate-tooling-sparse-checkout.sh"
	assert_success
}

@test "publish-file-breakdown: job uses static job-name input" {
	run grep -F 'name: ${{ inputs.job-name }}' "$WORKFLOW"
	assert_success
}

@test "publish-file-breakdown: runner-image and timeout-minutes are wired" {
	run grep -F 'runs-on: ${{ inputs.runner-image }}' "$WORKFLOW"
	assert_success
	run grep -F 'timeout-minutes: ${{ inputs.timeout-minutes }}' "$WORKFLOW"
	assert_success
}

@test "publish-file-breakdown: uses checkout-and-harden with scripts and post-pr-comment extras" {
	# Bootstrap sparse-checkout of the composite, then the single composite step.
	run grep -F '.github/actions/checkout-and-harden' "$WORKFLOW"
	assert_success
	run grep -F 'uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden' "$WORKFLOW"
	assert_success
	# Workflow-specific paths are preserved via sparse-checkout-extra.
	run grep -F 'sparse-checkout-extra:' "$WORKFLOW"
	assert_success
	run grep -F 'scripts/ci/' "$WORKFLOW"
	assert_success
	run grep -F '.github/actions/post-pr-comment' "$WORKFLOW"
	assert_success
	# Local harden-runner / resolve steps stay inside checkout-and-harden;
	# enforcement is a following direct step-security/harden-runner step.
	run grep -F '.github/actions/harden-runner' "$WORKFLOW"
	assert_failure
	run grep -F '.github/actions/resolve-egress-allowlist' "$WORKFLOW"
	assert_failure
	run grep -E 'uses:[[:space:]]+step-security/harden-runner@' "$WORKFLOW"
	assert_success
}

@test "publish-file-breakdown: defaults to github-minimal egress preset" {
	run awk '
		/egress-preset:/ { in_preset = 1 }
		in_preset && /default: "github-minimal"/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "publish-file-breakdown: publish job has pull-requests write permission" {
	run grep -F 'pull-requests: write' "$WORKFLOW"
	assert_success
}

@test "publish-file-breakdown: comment marker defaults to file-breakdown" {
	run awk '
		/comment-marker:/ { in_marker = 1 }
		in_marker && /default: "file-breakdown"/ { found = 1; in_marker = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "publish-file-breakdown: posts comment via post-pr-comment action" {
	run grep -F 'uses: ./.lgtm-ci-tooling/.github/actions/post-pr-comment' "$WORKFLOW"
	assert_success
	run grep -F 'marker: ${{ inputs.comment-marker }}' "$WORKFLOW"
	assert_success
}

@test "publish-file-breakdown: comment steps gate on detected PR number" {
	run grep -c "if: steps.pr.outputs.number != ''" "$WORKFLOW"
	assert_success
	assert_output "3"
}

@test "publish-file-breakdown: ci.yml wires file-breakdown job on pull_request" {
	local ci="${PROJECT_ROOT}/.github/workflows/ci.yml"
	run awk '
		/^  file-breakdown:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  file-breakdown:/ { in_job = 0 }
		in_job && /reusable-publish-file-breakdown\.yml/ { found = 1 }
		END { exit !found }
	' "$ci"
	assert_success
}
