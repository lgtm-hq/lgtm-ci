#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the reusable-docker orchestrator and family-wide
#          invariants shared by the focused Docker reusables (#381).

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker.yml"
BUILD_WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker-build.yml"
MULTI_WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform.yml"
SMOKE_WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker-smoke-test.yml"

# Workflows that carry docker/metadata-action blocks after the split.
_metadata_workflows() {
	cat "$BUILD_WORKFLOW" "$MULTI_WORKFLOW"
}

# Every workflow in the docker family.
_family_workflows() {
	cat "$WORKFLOW" "$BUILD_WORKFLOW" "$MULTI_WORKFLOW" "$SMOKE_WORKFLOW"
}

@test "reusable-docker: orchestrator delegates use-split=false to reusable-docker-build" {
	run awk '
		/^  build:/ { in_job = 1 }
		in_job && /if: \$\{\{ needs\.classify\.outputs\.use-split == .false. \}\}/ { has_if = 1 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-docker-build\.yml/ { has_uses = 1 }
		/^  multiplatform:/ { in_job = 0 }
		END { exit !(has_if && has_uses) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: orchestrator delegates use-split=true to reusable-docker-multiplatform" {
	run awk '
		/^  multiplatform:/ { in_job = 1 }
		in_job && /if: \$\{\{ needs\.classify\.outputs\.use-split == .true. \}\}/ { has_if = 1 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-docker-multiplatform\.yml/ { has_uses = 1 }
		in_job && /matrix: \$\{\{ needs\.classify\.outputs\.matrix \}\}/ { has_matrix = 1 }
		END { exit !(has_if && has_uses && has_matrix) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: orchestrator keeps classify job and runner-map input" {
	run grep -E '^  classify:$' "$WORKFLOW"
	assert_success
	run grep -E '^      runner-map:$' "$WORKFLOW"
	assert_success
	run grep -F 'STEP: classify' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: orchestrator holds no build or metadata steps of its own" {
	# The orchestrator is thin: build/metadata/login steps live in the focused
	# reusables, not here.
	run grep -F 'uses: docker/metadata-action@' "$WORKFLOW"
	assert_failure
	run grep -F 'uses: docker/build-push-action@' "$WORKFLOW"
	assert_failure
	run grep -F 'uses: docker/login-action@' "$WORKFLOW"
	assert_failure
}

@test "reusable-docker: orchestrator outputs come from build or multiplatform" {
	run grep -F 'value: ${{ jobs.build.outputs.tags || jobs.multiplatform.outputs.tags }}' "$WORKFLOW"
	assert_success
	run grep -F 'value: ${{ jobs.build.outputs.digest || jobs.multiplatform.outputs.digest }}' "$WORKFLOW"
	assert_success
}

@test "reusable-docker: orchestrator forwards backfill inputs to both nested calls" {
	# exact-tags / tag-latest / source-ref must flow through to both focused
	# reusables so backfill behavior is preserved on either path.
	local entry count
	for entry in \
		'exact-tags: ${{ inputs.exact-tags }}' \
		'tag-latest: ${{ inputs.tag-latest }}' \
		'source-ref: ${{ inputs.source-ref }}'; do
		count=$(grep -cF "$entry" "$WORKFLOW")
		[ "$count" -eq 2 ]
	done
}

@test "reusable-docker: orchestrator forwards secrets to both nested calls" {
	local count
	count=$(grep -cF 'DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}' "$WORKFLOW")
	[ "$count" -eq 2 ]
	count=$(grep -cF 'DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}' "$WORKFLOW")
	[ "$count" -eq 2 ]
}

@test "reusable-docker family: exposes target workflow input" {
	run grep -E '^      target:$' "$WORKFLOW"
	assert_success
	run grep -E '^      target:$' "$BUILD_WORKFLOW"
	assert_success
	run grep -E '^      target:$' "$MULTI_WORKFLOW"
	assert_success
}

@test "reusable-docker family: exposes health-check workflow inputs" {
	local wf
	for wf in "$WORKFLOW" "$BUILD_WORKFLOW" "$MULTI_WORKFLOW" "$SMOKE_WORKFLOW"; do
		run grep -E '^      health-check-cmd:$' "$wf"
		assert_success
		run grep -E '^      health-check-port:$' "$wf"
		assert_success
		run grep -E '^      health-check-timeout:$' "$wf"
		assert_success
	done
}

@test "reusable-docker family: exposes source-ref and tag-latest inputs" {
	local wf
	for wf in "$WORKFLOW" "$BUILD_WORKFLOW" "$MULTI_WORKFLOW"; do
		run grep -E '^      source-ref:$' "$wf"
		assert_success
		run grep -E '^      tag-latest:$' "$wf"
		assert_success
	done
}

@test "reusable-docker family: exposes exact-tags backfill input" {
	local wf
	for wf in "$WORKFLOW" "$BUILD_WORKFLOW" "$MULTI_WORKFLOW"; do
		run grep -E '^      exact-tags:$' "$wf"
		assert_success
	done
}

@test "reusable-docker family: app-source checkouts honor source-ref" {
	# Every app-source 'Checkout repository' uses source-ref (build context);
	# the count must match the number of app-source checkout steps, per file.
	local wf checkouts refs total=0
	for wf in "$WORKFLOW" "$BUILD_WORKFLOW" "$MULTI_WORKFLOW" "$SMOKE_WORKFLOW"; do
		checkouts=$(grep -cE '^      - name: Checkout repository' "$wf" || true)
		refs=$(grep -cF "ref: \${{ inputs.source-ref != '' && inputs.source-ref || github.sha }}" "$wf" || true)
		[ "$checkouts" -eq "$refs" ]
		total=$((total + refs))
	done
	[ "$total" -ge 6 ]
}

@test "reusable-docker family: tooling checkout stays on tooling-ref, not source-ref" {
	# The lgtm-ci tooling checkout must not be repointed by source-ref.
	run bash -c '
		cat "$0" "$1" "$2" "$3" | awk "
			/name: Checkout lgtm-ci tooling/ { in_tool = 1 }
			in_tool && /inputs\.source-ref/ { bad = 1; exit }
			in_tool && /^      - name:/ && !/Checkout lgtm-ci tooling/ { in_tool = 0 }
			END { exit bad }
		"
	' "$WORKFLOW" "$BUILD_WORKFLOW" "$MULTI_WORKFLOW" "$SMOKE_WORKFLOW"
	assert_success
}

@test "reusable-docker family: tag-latest gates the raw latest tag in every metadata block" {
	# Every metadata-action block that emits raw-latest must gate it on
	# tag-latest — assert the gated count equals the raw-latest count so a
	# block silently dropping the gate fails the test.
	local raw gated
	raw=$(_metadata_workflows | grep -cF 'type=raw,value=latest')
	gated=$(_metadata_workflows | grep -cF "type=raw,value=latest,enable=\${{ inputs.version != '' && inputs.tag-latest && !inputs.exact-tags }}")
	[ "$raw" -eq "$gated" ]
	[ "$gated" -ge 2 ]
	# No ungated raw-latest remains.
	run bash -c "cat \"\$0\" \"\$1\" | grep -E \"type=raw,value=latest,enable=\\\\\\\$\\{\\{ inputs.version != '' \\}\\}\"" \
		"$BUILD_WORKFLOW" "$MULTI_WORKFLOW"
	assert_failure
	# metadata-action's auto-latest is disabled in every block, so latest is
	# controlled solely by the gated raw entry (backfills never move latest).
	local metablocks flavor
	metablocks=$(_metadata_workflows | grep -c 'uses: docker/metadata-action@')
	flavor=$(_metadata_workflows | grep -c 'latest=false')
	[ "$flavor" -eq "$metablocks" ]
}

@test "reusable-docker family: exact-tags suppresses sha/branch/pr tags in every metadata block" {
	# Backfill mode must drop the mutable ref/sha floating tags from every
	# metadata-action block (build, build-per-platform, merge). Each entry must
	# carry the exact-tags gate exactly once per block.
	local blocks count entry
	blocks=$(_metadata_workflows | grep -c 'uses: docker/metadata-action@')
	[ "$blocks" -ge 3 ]
	for entry in 'type=sha,prefix=sha-' 'type=ref,event=branch' 'type=ref,event=pr'; do
		count=$(_metadata_workflows | grep -cF "${entry},enable=\${{ !inputs.exact-tags }}")
		[ "$count" -eq "$blocks" ]
	done
}

@test "reusable-docker family: exact-tags suppresses semver major and minor tags in every metadata block" {
	local blocks major minor
	blocks=$(_metadata_workflows | grep -c 'uses: docker/metadata-action@')
	major=$(_metadata_workflows | grep -cF \
		"type=semver,pattern={{major}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' && !inputs.exact-tags }}")
	minor=$(_metadata_workflows | grep -cF \
		"type=semver,pattern={{major}}.{{minor}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' && !inputs.exact-tags }}")
	[ "$major" -eq "$blocks" ]
	[ "$minor" -eq "$blocks" ]
}

@test "reusable-docker family: exact-tags keeps the pinned version tag in every metadata block" {
	# The version tag is the one tag a backfill must still publish; its enable
	# gate stays on version presence only, never on exact-tags.
	local blocks version gated
	blocks=$(_metadata_workflows | grep -c 'uses: docker/metadata-action@')
	version=$(_metadata_workflows | grep -cF \
		"type=semver,pattern={{version}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' }}")
	[ "$version" -eq "$blocks" ]
	# The version entry must not gain an exact-tags gate.
	gated=$(_metadata_workflows | grep -cF \
		"type=semver,pattern={{version}},value=\${{ inputs.version }},enable=\${{ inputs.version != '' && !inputs.exact-tags }}" || true)
	[ "$gated" -eq 0 ]
}

@test "reusable-docker family: does not delete staging manifests (they are index children)" {
	# Deleting the per-platform staging manifests orphans the merged index
	# (children 404). The destructive cleanup-staging step must be gone.
	local hits
	hits=$(_family_workflows | grep -cF 'STEP: cleanup-staging' || true)
	[ "$hits" -eq 0 ]
	hits=$(_family_workflows | grep -cF 'Delete staging manifests' || true)
	[ "$hits" -eq 0 ]
}

@test "reusable-docker family: registry logins go through the docker-auth composite" {
	# The focused reusables must use the shared docker-auth composite instead
	# of duplicated inline validate+login step sequences.
	local wf
	for wf in "$BUILD_WORKFLOW" "$MULTI_WORKFLOW" "$SMOKE_WORKFLOW"; do
		run grep -F 'uses: ./.lgtm-ci-tooling/.github/actions/docker-auth' "$wf"
		assert_success
		run grep -F 'uses: docker/login-action@' "$wf"
		assert_failure
	done
}

@test "reusable-docker family: exact-tags ignores additional tags" {
	# Every Parse-additional-tags step (build job, merge job) must be gated on
	# exact-tags and every metadata block must gate the extra-tags expansion.
	local parse_steps gated_extra_tags extra_tag_blocks
	extra_tag_blocks=$(_metadata_workflows | grep -cF -- "- name: Parse additional tags")
	parse_steps=$(_metadata_workflows | grep -cF "if: inputs.tags != '' && !inputs.exact-tags")
	gated_extra_tags=$(_metadata_workflows | grep -cF "\${{ !inputs.exact-tags && steps.extra-tags.outputs.tags || '' }}")
	[ "$parse_steps" -eq "$extra_tag_blocks" ]
	[ "$gated_extra_tags" -eq "$extra_tag_blocks" ]
	[ "$extra_tag_blocks" -ge 2 ]
}
