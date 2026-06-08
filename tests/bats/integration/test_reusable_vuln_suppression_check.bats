#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-vuln-suppression-check workflow inputs and job shape

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-vuln-suppression-check.yml"

@test "reusable-vuln-suppression-check: egress-policy defaults to block" {
	run awk '/^      egress-policy:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "block"'
}

@test "reusable-vuln-suppression-check: egress-preset defaults to osv-scanner" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "osv-scanner"'
}

@test "reusable-vuln-suppression-check: allowed-endpoints-mode defaults to append" {
	run awk '/^      allowed-endpoints-mode:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "append"'
}

@test "reusable-vuln-suppression-check: requires GH_TOKEN secret" {
	run awk '/^    secrets:$/,/^jobs:/' "$WORKFLOW"
	assert_success
	assert_output --partial 'GH_TOKEN:'
}

@test "reusable-vuln-suppression-check: job grants contents and pull-requests write" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /contents: write/ { contents = 1 }
		in_job && /pull-requests: write/ { prs = 1 }
		END { exit !(contents && prs) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: checkout uses caller GH_TOKEN for git push" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /- name: Checkout repository/ { checkout = 1 }
		checkout && /token: \$\{\{ secrets\.GH_TOKEN \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: default check script points to tooling script" {
	run grep -F \
		'default: ".lgtm-ci-tooling/scripts/ci/security/check-vuln-suppressions.sh"' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: resolve egress before harden-runner composite" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /- name: Checkout repository/ { checkout = 1 }
		in_job && /- name: Checkout lgtm-ci tooling/ { tooling = 1 }
		in_job && /- name: Resolve egress allowlist/ { resolve = 1 }
		in_job && resolve && /- name: Harden runner/ { found = 1 }
		END { exit !(checkout && tooling && found) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: installs osv-scanner before check step" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /- name: Install osv-scanner/ { install = 1 }
		install && /- name: Check suppression staleness/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}
