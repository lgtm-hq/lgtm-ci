#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the auto-rerun-on-infra-failure consumer workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/auto-rerun-on-infra-failure.yml"

@test "auto-rerun: triggers on workflow_run completion of CI" {
	run grep -F "workflow_run:" "$WORKFLOW"
	assert_success
	run grep -F 'workflows: ["CI"]' "$WORKFLOW"
	assert_success
	run grep -F "types: [completed]" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: gates on failed conclusion" {
	run grep -F "github.event.workflow_run.conclusion == 'failure'" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: calls the local reusable auto-rerun workflow" {
	run grep -F "uses: ./.github/workflows/reusable-auto-rerun-on-infra-failure.yml" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: passes the triggering run id and attempt" {
	run grep -F "run-id: \${{ format('{0}', github.event.workflow_run.id) }}" "$WORKFLOW"
	assert_success
	run grep -F "run-attempt: \${{ format('{0}', github.event.workflow_run.run_attempt) }}" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: raises max-reruns above the reusable default of 1" {
	# #833: a single retry does not converge runner-shutdown kill streaks.
	# workflow_run callers execute from the default branch, so this pin
	# is what actually takes effect for this repo.
	run grep -F 'max-reruns: "3"' "$WORKFLOW"
	assert_success
}

@test "auto-rerun example: documents max-reruns of 3" {
	local example="${PROJECT_ROOT}/examples/auto-rerun-on-infra-failure.yml"
	run grep -F 'max-reruns: "3"' "$example"
	assert_success
}

@test "auto-rerun: grants minimal required permissions" {
	run awk '
		/^  rerun:/ { in_job = 1; in_perms = 0 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /rerun:/ {
			in_job = 0
			in_perms = 0
		}
		in_job && /permissions:/ { in_perms = 1 }
		in_perms && /actions: write/ { found_actions = 1 }
		in_perms && /contents: read/ { found_contents = 1 }
		END { exit !(found_actions && found_contents) }
	' "$WORKFLOW"
	assert_success
}
