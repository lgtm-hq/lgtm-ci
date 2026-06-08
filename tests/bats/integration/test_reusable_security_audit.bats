#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-security-audit workflow inputs and job shape

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-security-audit.yml"

@test "reusable-security-audit: egress-policy defaults to block" {
	run awk '/^      egress-policy:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "block"'
}

@test "reusable-security-audit: egress-preset defaults to quality" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "quality"'
}

@test "reusable-security-audit: audit job uses continue-on-error" {
	run awk '
		/^  security-audit:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  security-audit:/ { in_job = 0 }
		in_job && /- name: Run security audit/ { audit = 1 }
		audit && /continue-on-error: true/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: explicit fail step after audit" {
	run awk '
		/- name: Run security audit/ { audit = 1 }
		audit && /- name: Fail on vulnerabilities/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	run grep -F "steps.audit.outcome == 'failure'" "$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: publish job uses post-pr-comment action" {
	run grep -F './.lgtm-ci-tooling/.github/actions/post-pr-comment' "$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: publish job skips fork PRs" {
	run grep -F 'github.event.pull_request.head.repo.fork == false' "$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: default audit script points to tooling run-lintro-audit.sh" {
	run grep -F 'default: ".lgtm-ci-tooling/scripts/ci/security/run-lintro-audit.sh"' "$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: resolve egress before harden-runner composite" {
	run awk '
		/^  security-audit:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  security-audit:/ { in_job = 0 }
		in_job && /- name: Checkout repository/ { checkout = 1 }
		in_job && /- name: Checkout lgtm-ci tooling/ { tooling = 1 }
		in_job && /- name: Resolve egress allowlist/ { resolve = 1 }
		in_job && resolve && /- name: Harden runner/ { found = 1 }
		END { exit !(checkout && tooling && found) }
	' "$WORKFLOW"
	assert_success
}
