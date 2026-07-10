#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-sbom workflow inputs and scan wiring (#480)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml"

@test "reusable-sbom: fail-on-severity defaults to critical" {
	run awk '/^      fail-on-severity:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "critical"'
}

@test "reusable-sbom: scan-vulnerabilities defaults to true" {
	run awk '/^      scan-vulnerabilities:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: true'
}

@test "reusable-sbom: egress-preset defaults to sbom" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "sbom"'
}

@test "reusable-sbom: scan step passes fail-on from fail-on-severity input" {
	run awk '
		/^  sbom:/ { in_job = 1; scan = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  sbom:/ { in_job = 0; scan = 0 }
		in_job && /- name: Scan vulnerabilities/ { scan = 1 }
		in_job && scan && /fail-on: \$\{\{ inputs\.fail-on-severity \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-sbom: scan step is gated on scan-vulnerabilities" {
	run awk '
		/^  sbom:/ { in_job = 1; scan = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  sbom:/ { in_job = 0; scan = 0 }
		in_job && /- name: Scan vulnerabilities/ { scan = 1 }
		in_job && scan && /if: inputs\.scan-vulnerabilities/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}
