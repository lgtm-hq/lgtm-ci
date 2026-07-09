#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-docker-multiplatform.yml (runner-map
#          matrix + manifest merge + signing path split out of
#          reusable-docker.yml, #381)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform.yml"

@test "reusable-docker-multiplatform: requires the classify matrix input" {
	run awk '
		/^      matrix:$/ { in_input = 1 }
		in_input && /^        required: true$/ { found = 1; exit }
		in_input && /^      [a-z-]+:$/ && !/^      matrix:$/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: per-platform jobs use static display names" {
	run grep -F 'name: Docker build per platform' "$WORKFLOW"
	assert_success
	run grep -F 'name: Docker verify per platform' "$WORKFLOW"
	assert_success
	run grep -F 'name: Docker health check per platform' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: preserves the build-<run_id>-<slug> staging tag scheme" {
	# The per-platform staging tags are the merged index's child manifests and
	# a separate pruner depends on this exact naming — do not change it.
	# yamllint disable-line rule:line-length
	run grep -F "format('{0}/{1}:build-{2}-{3}', inputs.registry, inputs.image-name || github.repository, github.run_id, matrix.slug)" "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: build-per-platform passes target input to build-push-action" {
	run grep -cE '^[[:space:]]+target: \$\{\{ inputs\.target \}\}$' "$WORKFLOW"
	assert_success
	assert_output "1"
}

@test "reusable-docker-multiplatform: build-per-platform job gates sbom on push" {
	run awk '
		/provenance: false/ { in_split = 1 }
		in_split && /sbom: \$\{\{ inputs\.sbom && inputs\.push \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: per-platform build avoids push and load together" {
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

@test "reusable-docker-multiplatform: merge job gates on health-check-per-platform success" {
	run grep -F 'needs.health-check-per-platform.result ==' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: health-check-per-platform waits for verify-per-platform" {
	run awk '
		/name: Docker health check per platform/ { in_job = 1 }
		in_job && /needs: \[build-per-platform, verify-per-platform\]/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: merge-manifests runs a non-skippable verify-published gate" {
	# The published index must be pulled back from the registry and verified;
	# a dangling index (children 404) must fail the release, not publish green.
	run grep -F 'STEP: verify-published' "$WORKFLOW"
	assert_success
	# Scope to the merge-manifests job: the verify step must live there (the
	# multi-arch publish path) and carry no if: guard that could skip it.
	run awk '
		/^  merge:/ { in_job = 1 }
		in_job && /^  [a-z].*:$/ && $0 !~ /^  merge:/ { in_job = 0 }
		in_job && /name: Verify published manifest/ { in_step = 1; found = 1; next }
		in_step && /^        if:/ { bad = 1; exit }
		in_step && /^      - name:/ { in_step = 0 }
		END { exit (bad || !found) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: does not delete staging manifests (they are index children)" {
	# Deleting the per-platform staging manifests orphans the merged index
	# (children 404). The destructive cleanup-staging step must be gone.
	run grep -F 'STEP: cleanup-staging' "$WORKFLOW"
	assert_failure
	run grep -F 'Delete staging manifests' "$WORKFLOW"
	assert_failure
}

@test "reusable-docker-multiplatform: staging digest artifacts flow between jobs" {
	run grep -cF 'name: staging-digest-${{ matrix.slug }}' "$WORKFLOW"
	assert_success
	# One upload (build-per-platform) + two downloads (verify, health-check).
	assert_output "3"
}

@test "reusable-docker-multiplatform: scan job scans the merged digest" {
	run grep -F 'needs.merge.outputs.digest }}' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: scan job authenticates before Trivy pull" {
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

@test "reusable-docker-multiplatform: registry logins use the docker-auth composite" {
	run grep -cF 'uses: ./.lgtm-ci-tooling/.github/actions/docker-auth' "$WORKFLOW"
	assert_success
	# build-per-platform, verify-per-platform, health-check-per-platform, merge, scan.
	assert_output "5"
}
