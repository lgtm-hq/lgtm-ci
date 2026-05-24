#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-docker workflow attestation gating

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker.yml"

@test "reusable-docker: build job passes target input to build-push-action" {
	run grep -E '^[[:space:]]+target: \$\{\{ inputs\.target \}\}$' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: build-per-platform job passes target input to build-push-action" {
	run grep -cE '^[[:space:]]+target: \$\{\{ inputs\.target \}\}$' "$WORKFLOW"
	assert_success
	assert_output "2"
}

@test "reusable-docker: exposes target workflow input" {
	run grep -E '^[[:space:]]+target:$' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: build job gates sbom and provenance on push" {
	run grep -E '^[[:space:]]+provenance: \$\{\{ inputs\.provenance && inputs\.push \}\}$' "$WORKFLOW"
	assert_success

	run grep -E '^[[:space:]]+sbom: \$\{\{ inputs\.sbom && inputs\.push \}\}$' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: build-per-platform job gates sbom on push" {
	run awk '
		/provenance: false/ { in_split = 1 }
		in_split && /sbom: \$\{\{ inputs\.sbom && inputs\.push \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: build job does not pass raw sbom or provenance inputs" {
	run grep -E '^[[:space:]]+(provenance|sbom): \$\{\{ inputs\.(provenance|sbom) \}\}$' "$WORKFLOW"
	assert_failure
}
