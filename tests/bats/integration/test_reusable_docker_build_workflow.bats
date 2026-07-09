#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-docker-build.yml (single-platform /
#          QEMU build path split out of reusable-docker.yml, #381)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker-build.yml"

@test "reusable-docker-build: build job passes target input to build-push-action" {
	run grep -cE '^[[:space:]]+target: \$\{\{ inputs\.target \}\}$' "$WORKFLOW"
	assert_success
	assert_output "1"
}

@test "reusable-docker-build: build job gates sbom and provenance on push" {
	run grep -E '^[[:space:]]+provenance: \$\{\{ inputs\.provenance && inputs\.push' "$WORKFLOW"
	assert_success

	run grep -E '^[[:space:]]+sbom: \$\{\{ inputs\.sbom && inputs\.push' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: build job does not pass raw sbom or provenance inputs" {
	run grep -E '^[[:space:]]+(provenance|sbom): \$\{\{ inputs\.(provenance|sbom) \}\}$' "$WORKFLOW"
	assert_failure
}

@test "reusable-docker-build: build job defers push when health-check-cmd is set" {
	run grep -E 'push: \$\{\{ inputs\.push && inputs\.health-check-cmd ==' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: build job publishes only after health check when enabled" {
	run grep -F 'Push image after health check' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: deferred push path generates SBOM attestation" {
	run grep -F 'Generate SBOM attestation' "$WORKFLOW"
	assert_success
	run grep -F 'uses: actions/attest@' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: scan job gates on build success, scan and push" {
	run awk '
		/^  scan:/ { in_job = 1 }
		in_job && /inputs\.scan &&/ { saw_scan = 1 }
		in_job && /inputs\.push &&/ { saw_push = 1 }
		in_job && /needs\.build\.result == .success./ { saw_result = 1 }
		END { exit !(saw_scan && saw_push && saw_result) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: scan job scans the built digest" {
	run grep -F 'needs.build.outputs.digest }}' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: scan job authenticates before Trivy pull" {
	run awk '
		/^  scan:/ { in_job = 1 }
		in_job && /^  [a-z]/ { if (!/^  scan:/) in_job = 0 }
		in_job && /sparse-checkout-extra:/ { saw_extra = 1 }
		in_job && /\.github\/actions\/docker-auth/ { saw_sparse = 1 }
		in_job && /name: Docker registry auth/ { saw_auth = 1 }
		in_job && /uses: \.\/\.lgtm-ci-tooling\/\.github\/actions\/docker-auth/ { saw_uses = 1 }
		in_job && /packages: read/ { saw_packages = 1 }
		END { exit !(saw_extra && saw_sparse && saw_auth && saw_uses && saw_packages) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: registry auth uses the docker-auth composite gated on push" {
	run awk '
		/name: Docker registry auth/ { in_step = 1 }
		in_step && /if: inputs\.push/ { has_if = 1 }
		in_step && /uses: \.\/\.lgtm-ci-tooling\/\.github\/actions\/docker-auth/ { has_uses = 1 }
		in_step && /^      - name:/ && !/Docker registry auth/ { in_step = 0 }
		END { exit !(has_if && has_uses) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-build: tooling sparse checkout includes docker-auth composite" {
	run grep -E '^[[:space:]]+\.github/actions/docker-auth$' "$WORKFLOW"
	assert_success
}
