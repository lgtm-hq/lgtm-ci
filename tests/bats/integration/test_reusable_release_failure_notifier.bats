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

@test "reusable-release-failure-notifier: requires workflow-key and tag inputs" {
	run grep -F "workflow-key:" "$WORKFLOW"
	assert_success
	run grep -F "tag:" "$WORKFLOW"
	assert_success
	run grep -F "required: true" "$WORKFLOW"
	assert_success
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
	run awk '
		/release-failure-notifier:/ { in_job = 1 }
		in_job && /needs: \[pypi-build, pypi-upload, github-release\]/ { found_needs = 1 }
		in_job && /if: always\(\)/ { found_always = 1 }
		in_job && /reusable-release-failure-notifier\.yml/ { found_reusable = 1 }
		in_job && /channels: \$\{\{ toJson\(needs\) \}\}/ { found_channels = 1 }
		END { exit !(found_needs && found_always && found_reusable && found_channels) }
	' "$EXAMPLE"
	assert_success
}

@test "example publish-python-release: notifier job grants issues write" {
	run awk '
		/release-failure-notifier:/ { in_job = 1 }
		in_job && /issues: write/ { found = 1 }
		END { exit !found }
	' "$EXAMPLE"
	assert_success
}
