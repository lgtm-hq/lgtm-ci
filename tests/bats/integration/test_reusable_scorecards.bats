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

@test "reusable-scorecards: upload-sarif conditional checks upload-sarif and results-format" {
	run awk '
		/^  scorecards:/ { in_job = 1; upload = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; upload = 0 }
		in_job && /- name: Upload SARIF/ { upload = 1 }
		in_job && upload && /^        if:/ {
			if ($0 ~ /inputs\.upload-sarif/ && $0 ~ /inputs\.results-format == '\''sarif'\''/) {
				found = 1
				exit
			}
		}
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

@test "reusable-scorecards: scorecard job uses only publish-allowlisted actions" {
	# ossf/scorecard-action publish path forbids any step besides checkout,
	# upload-artifact, upload-sarif, scorecard-action, harden-runner (#518).
	run awk '
		/^  scorecards:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0 }
		in_job && /^        uses: / {
			ok = /uses: (actions\/checkout|actions\/upload-artifact|github\/codeql-action\/upload-sarif|ossf\/scorecard-action|step-security\/harden-runner)@/
			if (!ok) { print "unallowed: " $0; bad = 1 }
		}
		END { exit bad }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: drops deprecated no-op tooling/egress inputs" {
	run grep -qE '^      tooling-ref:' "$WORKFLOW"
	assert_failure
	run grep -qE '^      allowed-endpoints-mode:' "$WORKFLOW"
	assert_failure
	run grep -qE '^      egress-preset:' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.tooling-ref' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.allowed-endpoints-mode' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.egress-preset' "$WORKFLOW"
	assert_failure
}
