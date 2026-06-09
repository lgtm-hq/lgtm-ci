#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-docker workflow attestation gating

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker.yml"

@test "reusable-docker: per-platform jobs use static display names" {
	run grep -F 'name: Docker build per platform' "$WORKFLOW"
	assert_success
	run grep -F 'name: Docker verify per platform' "$WORKFLOW"
	assert_success
}

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
	run grep -E '^[[:space:]]+provenance: \$\{\{ inputs\.provenance && inputs\.push' "$WORKFLOW"
	assert_success

	run grep -E '^[[:space:]]+sbom: \$\{\{ inputs\.sbom && inputs\.push' "$WORKFLOW"
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

@test "reusable-docker: exposes health-check workflow inputs" {
	run grep -E '^[[:space:]]+health-check-cmd:$' "$WORKFLOW"
	assert_success
	run grep -E '^[[:space:]]+health-check-port:$' "$WORKFLOW"
	assert_success
	run grep -E '^[[:space:]]+health-check-timeout:$' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: per-platform jobs use static health-check display name" {
	run grep -F 'name: Docker health check per platform' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: merge job gates on health-check-per-platform success" {
	run grep -F 'needs.health-check-per-platform.result ==' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: build job defers push when health-check-cmd is set" {
	run grep -E 'push: \$\{\{ inputs\.push && inputs\.health-check-cmd ==' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: per-platform build avoids push and load together" {
	run awk '
		/name: Build and push \(\$\{\{ matrix\.platform \}\}\)/ { in_step = 1 }
		in_step && /push: \$\{\{ inputs\.push \}\}/ { saw_push = 1 }
		in_step && /load:/ { saw_load = 1 }
		in_step && saw_push && saw_load {
			if ($0 ~ /inputs\.push == false && \(inputs\.health-check-cmd/) {
				found = 1
				exit
			}
		}
		in_step && /^[[:space:]]+- name:/ && !/Build and push/ { in_step = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: build job publishes only after health check when enabled" {
	run grep -F 'Push image after health check' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: health-check-per-platform waits for verify-per-platform" {
	run grep -F 'needs: [classify, build-per-platform, verify-per-platform]' "$WORKFLOW" | grep -c 'health-check-per-platform' || true
	run awk '
		/name: Docker health check per platform/ { in_job = 1 }
		in_job && /needs: \[classify, build-per-platform, verify-per-platform\]/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: deferred push path generates SBOM attestation" {
	run grep -F 'Generate SBOM attestation' "$WORKFLOW"
	assert_success
	run grep -F 'uses: actions/attest@' "$WORKFLOW"
	assert_success
}
