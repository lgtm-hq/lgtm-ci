#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-scorecards workflow (#329)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-scorecards.yml"

@test "reusable-scorecards: results-file defaults to results.sarif" {
	run awk '/^      results-file:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "results.sarif"'
}

@test "reusable-scorecards: scorecard step passes repo_token" {
	run awk '
		/^  scorecards:/ { in_job = 1; scorecard = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; scorecard = 0 }
		in_job && /- name: Run OpenSSF Scorecard/ { scorecard = 1 }
		in_job && scorecard && /repo_token: \$\{\{ github\.token \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: scorecard step passes results_file" {
	run awk '
		/^  scorecards:/ { in_job = 1; scorecard = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; scorecard = 0 }
		in_job && /- name: Run OpenSSF Scorecard/ { scorecard = 1 }
		in_job && scorecard && /results_file: \$\{\{ inputs\.results-file \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: upload-sarif uses results-file input" {
	run awk '
		/^  scorecards:/ { in_job = 1; upload = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; upload = 0 }
		in_job && /- name: Upload SARIF/ { upload = 1 }
		in_job && upload && /sarif_file: \$\{\{ inputs\.results-file \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: resolve egress before harden-runner composite" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" scorecards
	assert_success
}
