#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-release-multi-ecosystem.yml

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-release-multi-ecosystem.yml"

@test "reusable-release-multi-ecosystem: defines workflow_call inputs and secrets" {
	run grep -F "workflow_call:" "$WORKFLOW"
	assert_success
	run grep -F "manifests:" "$WORKFLOW"
	assert_success
	run grep -F "bump:" "$WORKFLOW"
	assert_success
	run grep -F "prerelease-tag:" "$WORKFLOW"
	assert_success
	run grep -F "changelog:" "$WORKFLOW"
	assert_success
	run grep -F "job-name:" "$WORKFLOW"
	assert_success
	run grep -F "tooling-ref:" "$WORKFLOW"
	assert_success
	run awk '
		/^      RELEASE_APP_ID:/ {
			while ((getline line) > 0) {
				if (line ~ /^      [A-Za-z_][A-Za-z0-9_-]+:/) {
					break
				}
				if (line ~ /^        required: true$/) {
					found_app_id = 1
					break
				}
			}
		}
		END { exit !found_app_id }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-multi-ecosystem: uses App token for create-pull-request" {
	run awk '
		/- name: Create or update version PR/ { in_step = 1 }
		in_step && /peter-evans\/create-pull-request/ { saw_cpr = 1 }
		in_step && /token: \$\{\{ steps\.app-token\.outputs\.token \}\}/ { saw_token = 1 }
		in_step && /sign-commits: true/ { saw_sign = 1 }
		in_step && /^      - name:/ && $0 !~ /Create or update version PR/ { in_step = 0 }
		END { exit !(saw_cpr && saw_token && saw_sign) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-multi-ecosystem: dispatches manifests runner" {
	run grep -F "ecosystems/_manifests_runner.sh" "$WORKFLOW"
	assert_success
	run grep -F "resolve-multi-ecosystem-version.sh" "$WORKFLOW"
	assert_success
}

@test "reusable-release-multi-ecosystem: gates create-pull-request on merge-queue skip" {
	run grep -F "check-version-pr-merge-queue.sh" "$WORKFLOW"
	assert_success
	run awk '
		/- name: Create or update version PR/ { in_step = 1 }
		in_step && /skip-branch-update != '\''true'\''/ { found = 1; exit }
		in_step && /^      - name:/ && $0 !~ /Create or update version PR/ { in_step = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-multi-ecosystem: exposes runner-image on all jobs" {
	run awk '
		/^  version-pr:/ { in_job = 1 }
		/^  report-release-failure:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  version-pr:/ && !/^  report-release-failure:/ { in_job = 0 }
		in_job && /^    runs-on: \$\{\{ inputs\.runner-image \}\}$/ { found++ }
		END { exit found != 2 }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-multi-ecosystem: defines report-release-failure follow-up" {
	run grep -F "report-release-failure:" "$WORKFLOW"
	assert_success
	run grep -F "RELEASE_WORKFLOW_KEY: release-multi-ecosystem" "$WORKFLOW"
	assert_success
}

@test "reusable-release-multi-ecosystem: uses job-name for primary job" {
	run awk '
		/^  version-pr:/ { in_job = 1 }
		in_job && /^    name: \$\{\{ inputs\.job-name \}\}$/ { found = 1; exit }
		in_job && /^  [a-zA-Z0-9_-]+:/ && !/^  version-pr:/ { in_job = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-release-multi-ecosystem: removes tooling before PR creation" {
	run awk '
		/^  version-pr:/ { in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:/ { in_job = 0 }
		in_job && /- name: Remove tooling checkout before PR creation/ { saw_remove = 1 }
		in_job && saw_remove && /- name: Create or update version PR/ { saw_create = 1; exit }
		END { exit !(saw_remove && saw_create) }
	' "$WORKFLOW"
	assert_success
}
