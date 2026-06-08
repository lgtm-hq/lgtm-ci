#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-security-audit workflow inputs and job shape

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-security-audit.yml"
PUBLISH_WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-publish-security-audit-comment.yml"

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
		/^  security-audit:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  security-audit:/ { in_job = 0 }
		in_job && /- name: Run security audit/ { audit = 1 }
		in_job && audit && /- name: Fail on vulnerabilities/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	run awk '
		/^  security-audit:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  security-audit:/ { in_job = 0 }
		in_job && /steps\.audit\.outcome == '\''failure'\''/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: no pull-requests permission" {
	run awk '
		/^jobs:/ { in_jobs = 1 }
		in_jobs && /^[^ ]/ && !/^jobs:/ { in_jobs = 0 }
		in_jobs && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: upload-artifact uses upload repo v7 SHA" {
	run grep -F 'uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-security-audit: does not pin download-artifact" {
	run grep -F 'actions/download-artifact@' "$WORKFLOW"
	assert_failure
}

@test "reusable-publish-security-audit-comment: uses post-pr-comment action" {
	run grep -F './.lgtm-ci-tooling/.github/actions/post-pr-comment' "$PUBLISH_WORKFLOW"
	assert_success
}

@test "reusable-publish-security-audit-comment: download-artifact uses download repo v8 SHA" {
	run grep -F 'uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1' \
		"$PUBLISH_WORKFLOW"
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
