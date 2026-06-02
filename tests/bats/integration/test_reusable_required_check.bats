#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-required-check workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-required-check.yml"

@test "reusable-required-check: job-name input is required" {
	run awk '
		/^      job-name:/ {
			while ((getline line) > 0) {
				if (line ~ /^      [a-zA-Z0-9_-]+:/) {
					break
				}
				if (line ~ /^        required: true$/) {
					found = 1
					break
				}
			}
		}
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-required-check: gate job uses job-name for display name" {
	run awk '
		/^  gate:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  gate:/ { in_job = 0 }
		in_job && /^    name: \$\{\{ inputs\.job-name \}\}$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-required-check: upstream-result input is required" {
	run awk '
		/^      upstream-result:/ {
			while ((getline line) > 0) {
				if (line ~ /^      [a-zA-Z0-9_-]+:/) {
					break
				}
				if (line ~ /^        required: true$/) {
					found = 1
					break
				}
			}
		}
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-required-check: uses harden-runner and tooling checkout" {
	run grep -E '^\s*uses:\s*\./\.github/actions/harden-runner\s*$' "$WORKFLOW"
	assert_success
	run awk '
		/- name: Checkout repository/ { checkout = 1 }
		checkout && /- name: Harden runner/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	run grep -Ei '^\s*uses:\s*.*step-security/harden-runner' "$WORKFLOW"
	assert_failure
	run awk '
		/Checkout lgtm-ci tooling/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	run grep -F 'scripts/ci/' "$WORKFLOW"
	assert_success
}

@test "reusable-required-check: assert step invokes assert-required-check.sh" {
	run awk '
		/Assert required check/ { in_step = 1 }
		in_step && /assert-required-check\.sh/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-required-check: passes upstream-result to assert script env" {
	run awk '
		/UPSTREAM_RESULT: \$\{\{ inputs\.upstream-result \}\}/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-required-check: gate job uses always() with draft-pr-skip guard" {
	run awk '
		/^  gate:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  gate:/ { in_job = 0 }
		in_job && /^    if:/ { if_line = 1 }
		if_line && /always\(\)/ { found_always = 1 }
		if_line && /draft-pr-skip/ { found_draft = 1 }
		END { exit !(found_always && found_draft) }
	' "$WORKFLOW"
	assert_success
}
