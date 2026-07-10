#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the main-failure-notifier caller in ci.yml

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/ci.yml"

@test "ci.yml: defines notify-failure job" {
	run grep -F "notify-failure:" "$WORKFLOW"
	assert_success
}

@test "ci.yml: notify-failure depends on main jobs" {
	run grep -F "needs: [quality, shell-tests]" "$WORKFLOW"
	assert_success
}

@test "ci.yml: notify-failure gates on failure and main branch" {
	run grep -F "failure()" "$WORKFLOW"
	assert_success
	run grep -F "github.ref == 'refs/heads/main'" "$WORKFLOW"
	assert_success
}

@test "ci.yml: notify-failure calls reusable-main-failure-notifier" {
	run grep -F "reusable-main-failure-notifier.yml" "$WORKFLOW"
	assert_success
}

@test "ci.yml: notify-failure passes workflow-key" {
	run grep -F "workflow-key: ci" "$WORKFLOW"
	assert_success
}

@test "ci.yml: notify-failure grants minimal required permissions" {
	run awk '
		/notify-failure:/ { in_job = 1; in_perms = 0 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /notify-failure:/ {
			in_job = 0
			in_perms = 0
		}
		in_job && /permissions:/ { in_perms = 1 }
		in_perms && /actions: read/ { found_actions = 1 }
		in_perms && /contents: read/ { found_contents = 1 }
		in_perms && /issues: write/ { found_issues = 1 }
		END { exit !(found_actions && found_contents && found_issues) }
	' "$WORKFLOW"
	assert_success
}
