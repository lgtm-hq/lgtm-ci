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

@test "reusable-docker: merge-manifests runs a non-skippable verify-published gate" {
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

@test "reusable-docker: does not delete staging manifests (they are index children)" {
	# Deleting the per-platform staging manifests orphans the merged index
	# (children 404). The destructive cleanup-staging step must be gone.
	run grep -F 'STEP: cleanup-staging' "$WORKFLOW"
	assert_failure
	run grep -F 'Delete staging manifests' "$WORKFLOW"
	assert_failure
}

@test "reusable-docker: exposes source-ref and tag-latest inputs" {
	run grep -E '^      source-ref:$' "$WORKFLOW"
	assert_success
	run grep -E '^      tag-latest:$' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: app-source checkouts honor source-ref" {
	# Every app-source 'Checkout repository' uses source-ref (build context);
	# the count must match the number of app-source checkout steps.
	local checkouts refs
	checkouts=$(grep -cE '^      - name: Checkout repository' "$WORKFLOW")
	refs=$(grep -cF "ref: \${{ inputs.source-ref != '' && inputs.source-ref || github.sha }}" "$WORKFLOW")
	[ "$checkouts" -eq "$refs" ]
	[ "$refs" -ge 6 ]
}

@test "reusable-docker: tooling checkout stays on tooling-ref, not source-ref" {
	# The lgtm-ci tooling checkout must not be repointed by source-ref.
	run awk '
		/name: Checkout lgtm-ci tooling/ { in_tool = 1 }
		in_tool && /inputs\.source-ref/ { bad = 1; exit }
		in_tool && /^      - name:/ && !/Checkout lgtm-ci tooling/ { in_tool = 0 }
		END { exit bad }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: tag-latest gates the raw latest tag in every metadata block" {
	# Every metadata-action block that emits raw-latest must gate it on
	# tag-latest — assert the gated count equals the raw-latest count so a
	# block silently dropping the gate fails the test.
	local raw gated
	raw=$(grep -cF 'type=raw,value=latest' "$WORKFLOW")
	gated=$(grep -cF "type=raw,value=latest,enable=\${{ inputs.version != '' && inputs.tag-latest && !inputs.exact-tags }}" "$WORKFLOW")
	[ "$raw" -eq "$gated" ]
	[ "$gated" -ge 2 ]
	# No ungated raw-latest remains.
	run grep -E "type=raw,value=latest,enable=\\\$\{\{ inputs.version != '' \}\}" "$WORKFLOW"
	assert_failure
	# metadata-action's auto-latest is disabled in every block, so latest is
	# controlled solely by the gated raw entry (backfills never move latest).
	local metablocks flavor
	metablocks=$(grep -c 'uses: docker/metadata-action@' "$WORKFLOW")
	flavor=$(grep -c 'latest=false' "$WORKFLOW")
	[ "$flavor" -eq "$metablocks" ]
}

@test "reusable-docker: exposes exact-tags backfill input" {
	run grep -E '^      exact-tags:$' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: exact-tags suppresses sha/branch/pr tags in every metadata block" {
	# Backfill mode must drop the mutable ref/sha floating tags from every
	# metadata-action block (build, build-per-platform, merge). Each entry must
	# carry the exact-tags gate exactly once per block.
	local blocks count entry
	blocks=$(grep -c 'uses: docker/metadata-action@' "$WORKFLOW")
	[ "$blocks" -ge 3 ]
	for entry in 'type=sha,prefix=sha-' 'type=ref,event=branch' 'type=ref,event=pr'; do
		count=$(grep -cF "${entry},enable=\${{ !inputs.exact-tags }}" "$WORKFLOW")
		[ "$count" -eq "$blocks" ]
	done
}

@test "reusable-docker: exact-tags suppresses semver major and minor tags in every metadata block" {
	local blocks major minor
	blocks=$(grep -c 'uses: docker/metadata-action@' "$WORKFLOW")
	major=$(grep -cF \
		"type=semver,pattern={{major}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' && !inputs.exact-tags }}" \
		"$WORKFLOW")
	minor=$(grep -cF \
		"type=semver,pattern={{major}}.{{minor}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' && !inputs.exact-tags }}" \
		"$WORKFLOW")
	[ "$major" -eq "$blocks" ]
	[ "$minor" -eq "$blocks" ]
}

@test "reusable-docker: exact-tags keeps the pinned version tag in every metadata block" {
	# The version tag is the one tag a backfill must still publish; its enable
	# gate stays on version presence only, never on exact-tags.
	local blocks version
	blocks=$(grep -c 'uses: docker/metadata-action@' "$WORKFLOW")
	version=$(grep -cF \
		"type=semver,pattern={{version}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' }}" \
		"$WORKFLOW")
	[ "$version" -eq "$blocks" ]
	# The version entry must not gain an exact-tags gate.
	run grep -F \
		"type=semver,pattern={{version}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' && !inputs.exact-tags }}" \
		"$WORKFLOW"
	assert_failure
}

@test "reusable-docker: exact-tags ignores additional tags" {
	local parse_steps gated_extra_tags extra_tag_blocks
	extra_tag_blocks=$(grep -cF -- "- name: Parse additional tags" "$WORKFLOW")
	parse_steps=$(grep -cF "if: inputs.tags != '' && !inputs.exact-tags" "$WORKFLOW")
	gated_extra_tags=$(grep -cF "\${{ !inputs.exact-tags && steps.extra-tags.outputs.tags || '' }}" "$WORKFLOW")
	[ "$parse_steps" -eq "$extra_tag_blocks" ]
	[ "$gated_extra_tags" -eq "$extra_tag_blocks" ]
	[ "$extra_tag_blocks" -ge 2 ]
}
