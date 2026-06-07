#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for release failure reporting in reusable workflows

load "../../helpers/common"

@test "reusable-release-version-pr: defines report-release-failure follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run grep -F "report-release-failure:" "$workflow"
	assert_success
	run grep -F "needs.version-pr.result == 'failure'" "$workflow"
	assert_success
	run grep -F "inputs.report-failures" "$workflow"
	assert_success
	run grep -F "failure-issue-labels:" "$workflow"
	assert_success
	run grep -F "failure-target-branch:" "$workflow"
	assert_success
}

@test "reusable-release-auto-tag: defines report-release-failure follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run grep -F "report-release-failure:" "$workflow"
	assert_success
	run grep -F "needs.auto-tag.result == 'failure'" "$workflow"
	assert_success
	run grep -F "inputs.report-failures" "$workflow"
	assert_success
	run grep -F "failure-issue-labels:" "$workflow"
	assert_success
	run grep -F "failure-target-branch:" "$workflow"
	assert_success
}

@test "reusable-release-version-pr: hardens egress on failure follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run awk '
		/report-release-failure:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
		}
		in_job && /harden-runner/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
	run awk '
		/report-release-failure:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
		}
		in_job && /egress-preset: github-minimal/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-release-auto-tag: hardens egress on failure follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run awk '
		/report-release-failure:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
		}
		in_job && /harden-runner/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
	run awk '
		/report-release-failure:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
		}
		in_job && /egress-preset: github-minimal/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-release-version-pr: grants issues write to failure follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run awk '
		/report-release-failure:/ { in_job = 1; in_perms = 0 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
			in_perms = 0
		}
		in_job && /permissions:/ { in_perms = 1 }
		in_perms && /issues: write/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
	run awk '
		/report-release-failure:/ { in_job = 1; in_perms = 0 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
			in_perms = 0
		}
		in_job && /permissions:/ { in_perms = 1 }
		in_perms && /actions: read/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-release-auto-tag: grants issues write to failure follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run awk '
		/report-release-failure:/ { in_job = 1; in_perms = 0 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
			in_perms = 0
		}
		in_job && /permissions:/ { in_perms = 1 }
		in_perms && /issues: write/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
	run awk '
		/report-release-failure:/ { in_job = 1; in_perms = 0 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /report-release-failure:/ {
			in_job = 0
			in_perms = 0
		}
		in_job && /permissions:/ { in_perms = 1 }
		in_perms && /actions: read/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable release workflows: wire distinct workflow keys" {
	local version_pr="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
	local auto_tag="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run awk '
		/report-release-failure:/ { in_job = 1 }
		in_job && /RELEASE_WORKFLOW_KEY: release-version-pr/ { found = 1; exit }
		END { exit !found }
	' "$version_pr"
	assert_success
	run awk '
		/report-release-failure:/ { in_job = 1 }
		in_job && /RELEASE_WORKFLOW_KEY: release-auto-tag/ { found = 1; exit }
		END { exit !found }
	' "$auto_tag"
	assert_success
}

@test "reusable release workflows: call report-release-failure helper" {
	local version_pr="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
	local auto_tag="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run grep -F "report-release-failure.sh" "$version_pr"
	assert_success
	run grep -F "write_trigger_summary" "$version_pr"
	assert_success
	run grep -F "notify_failure" "$version_pr"
	assert_success
	run grep -F "report-release-failure.sh" "$auto_tag"
	assert_success
	run grep -F "write_trigger_summary" "$auto_tag"
	assert_success
	run grep -F "notify_failure" "$auto_tag"
	assert_success
}
