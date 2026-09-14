#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-release-failure-notifier.yml (#964)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-release-failure-notifier.yml"
EXAMPLE="${PROJECT_ROOT}/examples/publish-python-release.yml"

@test "reusable-release-failure-notifier: notify job runs always()" {
	run grep -F "if: always()" "$WORKFLOW"
	assert_success
}

# Print the `required:` value of one workflow_call input, scoped to that
# input's block so a `required: true` elsewhere cannot satisfy the check.
input_required_value() {
	local input="$1"
	awk -v input="$input" '
		$0 ~ "^      " input ":$" { in_input = 1; next }
		in_input && /^      [A-Za-z_-]+:$/ { in_input = 0 }
		in_input && /^        required:/ { print $2; exit }
	' "$WORKFLOW"
}

@test "reusable-release-failure-notifier: requires workflow-key and tag inputs" {
	run input_required_value "workflow-key"
	assert_output "true"
	run input_required_value "tag"
	assert_output "true"
	# The opt-in inputs stay optional.
	run input_required_value "max-reruns"
	assert_output "false"
}

@test "reusable-release-failure-notifier: rerun suppression is opt-in and shares the signature extension" {
	# Default 0: a caller without the auto-rerun reusable never gets a silent
	# "rerunning" verdict for a re-run nothing will start.
	run awk '
		/^      max-reruns:$/ { in_input = 1; next }
		in_input && /^      [A-Za-z_-]+:$/ { in_input = 0 }
		in_input && /^        default:/ { print $2; exit }
	' "$WORKFLOW"
	assert_output "0"
	run grep -F "INFRA_SIGNATURES: \${{ inputs.signatures }}" "$WORKFLOW"
	assert_success
	run grep -F "FAILURE_REASON: \${{ steps.classify.outputs.reason }}" "$WORKFLOW"
	assert_success
}

@test "reusable-release-failure-notifier: serializes runs per repository, key and tag" {
	run awk '
		/^  notify:/ { in_job = 1; next }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { in_job = 0 }
		in_job && /group: release-failure-\$\{\{ github.repository \}\}-\$\{\{ inputs.workflow-key \}\}-\$\{\{ inputs.tag \}\}/ { found_group = 1 }
		in_job && /cancel-in-progress: false/ { found_no_cancel = 1 }
		END { exit !(found_group && found_no_cancel) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-failure-notifier: refuses unenforceable block egress before tokenized steps" {
	# harden-runner stays the first step (validate-harden-runner-action-ref);
	# the guard is the second, so nothing with GH_TOKEN runs before it.
	run awk '
		/^    steps:/ { in_steps = 1; next }
		in_steps && /^      - name:/ { n++; print n ": " $0; if (n == 2) exit }
	' "$WORKFLOW"
	assert_output --partial "1:       - name: Harden runner"
	assert_output --partial "2:       - name: Refuse block egress"
	run awk '
		/Refuse block egress/ { in_step = 1; next }
		in_step && /^      - name:/ { exit }
		in_step { print }
	' "$WORKFLOW"
	assert_output --partial "inputs.egress-policy == 'block' &&"
	assert_output --partial "runner.os != 'Linux' &&"
	assert_output --partial "runner.environment != 'self-hosted'"
}

@test "reusable-release-failure-notifier: classifies then files or closes" {
	run grep -F "classify_release_failure" "$WORKFLOW"
	assert_success
	run grep -F "notify_release_failure" "$WORKFLOW"
	assert_success
	run grep -F "close_release_failure" "$WORKFLOW"
	assert_success
	# File and close are gated on the classify verdict; both share one call.
	run grep -F "steps.classify.outputs.verdict == 'failure'" "$WORKFLOW"
	assert_success
	run grep -F "steps.classify.outputs.verdict == 'success'" "$WORKFLOW"
	assert_success
}

@test "reusable-release-failure-notifier: passes tag, channels, and rerun budget" {
	run grep -F "RELEASE_TAG: \${{ inputs.tag }}" "$WORKFLOW"
	assert_success
	run grep -F "CHANNELS_JSON: \${{ inputs.channels }}" "$WORKFLOW"
	assert_success
	run grep -F "RUN_ATTEMPT: \${{ github.run_attempt }}" "$WORKFLOW"
	assert_success
	run grep -F "MAX_RERUNS: \${{ inputs.max-reruns }}" "$WORKFLOW"
	assert_success
}

@test "reusable-release-failure-notifier: hardens egress on the notify job" {
	run awk '
		/^  notify:/ { in_job = 1; next }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { in_job = 0 }
		in_job && /harden-runner/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	run awk '
		/^  notify:/ { in_job = 1; next }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { in_job = 0 }
		in_job && /egress-preset: github-minimal/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-failure-notifier: grants minimal permissions to the notify job" {
	run awk '
		/^  notify:/ { in_job = 1; in_perms = 0; next }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { in_job = 0; in_perms = 0 }
		in_job && /permissions:/ { in_perms = 1 }
		in_job && in_perms && /issues: write/ { found_issues = 1 }
		in_job && in_perms && /actions: read/ { found_actions = 1 }
		# Least privilege: the notifier never writes repository content.
		in_job && in_perms && /contents: write/ { found_contents_write = 1 }
		END { exit !(found_issues && found_actions && !found_contents_write) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-failure-notifier: labels default to the release set" {
	run awk '
		/failure-issue-labels:/ { in_input = 1; next }
		in_input && /default:/ { print; exit }
	' "$WORKFLOW"
	assert_output --partial "bug,ci,release,automation,infrastructure"
}

@test "example publish-python-release: wires the release-mode notifier last" {
	run grep -F "release-failure-notifier:" "$EXAMPLE"
	assert_success
	# Scoped to the notifier job: the scan stops at the next top-level job, so
	# a later job cannot satisfy these checks.
	run awk '
		/^  release-failure-notifier:/ { in_job = 1; next }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { in_job = 0 }
		in_job && /needs: \[pypi-build, pypi-upload, github-release\]/ { found_needs = 1 }
		in_job && /if: always\(\)/ { found_always = 1 }
		in_job && /reusable-release-failure-notifier\.yml/ { found_reusable = 1 }
		in_job && /channels: \$\{\{ toJson\(needs\) \}\}/ { found_channels = 1 }
		END { exit !(found_needs && found_always && found_reusable && found_channels) }
	' "$EXAMPLE"
	assert_success
	# docs/workflow-contract.md: every tag-publish workflow MUST end with the
	# release-mode notifier, so no top-level job may follow it.
	run awk '
		/^  release-failure-notifier:/ { seen = 1; next }
		seen && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { print "job after notifier: " $1; exit 1 }
	' "$EXAMPLE"
	assert_success
	assert_output ""
}

@test "example publish-python-release: notifier job grants issues write" {
	run awk '
		/^  release-failure-notifier:/ { in_job = 1; next }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { in_job = 0 }
		in_job && /issues: write/ { found = 1 }
		END { exit !found }
	' "$EXAMPLE"
	assert_success
}
