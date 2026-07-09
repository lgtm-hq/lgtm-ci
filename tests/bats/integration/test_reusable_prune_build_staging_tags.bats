#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the prune-build-staging-tags workflows

load "../../helpers/common"

REUSABLE="${PROJECT_ROOT}/.github/workflows/reusable-prune-build-staging-tags.yml"
DISPATCHER="${PROJECT_ROOT}/.github/workflows/prune-build-staging-tags.yml"

@test "reusable-prune: threshold-days defaults to 30" {
	run awk '/^      threshold-days:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$REUSABLE"
	assert_success
	assert_output --partial "default: 30"
}

@test "reusable-prune: dry-run defaults to true (safe by default)" {
	run awk '/^      dry-run:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$REUSABLE"
	assert_success
	assert_output --partial "default: true"
}

@test "reusable-prune: protect-referenced defaults to true (#433 safety gate)" {
	run awk '/^      protect-referenced:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$REUSABLE"
	assert_success
	assert_output --partial "default: true"
}

@test "reusable-prune: egress preset defaults to docker (needs ghcr.io registry)" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$REUSABLE"
	assert_success
	assert_output --partial 'default: "docker"'
}

@test "reusable-prune: passes threshold, keep-recent, protection, and dry-run env vars" {
	run awk '
		/- name: Prune build/ { step = 1 }
		step && /THRESHOLD_DAYS:/ { threshold = 1 }
		step && /KEEP_RECENT:/ { keep = 1 }
		step && /PROTECT_REFERENCED:/ { protect = 1 }
		step && /DRY_RUN:/ { dry = 1 }
		END { exit !(threshold && keep && protect && dry) }
	' "$REUSABLE"
	assert_success
}

@test "reusable-prune: runs the dedicated pruner script (no inline shell logic)" {
	run grep -q "scripts/ci/maintenance/prune-build-staging-tags.sh" "$REUSABLE"
	assert_success
}

@test "reusable-prune: requires packages:write for the prune job" {
	run awk '/^  prune-staging:$/{show=1} show&&/packages: write/{found=1} END{exit !found}' \
		"$REUSABLE"
	assert_success
}

@test "dispatcher-prune: scheduled runs stay in dry-run mode" {
	run grep -qE "dry-run: \\$\\{\\{ github.event_name != 'workflow_dispatch'" "$DISPATCHER"
	assert_success
}

@test "dispatcher-prune: calls the reusable prune workflow" {
	run grep -q "uses: ./.github/workflows/reusable-prune-build-staging-tags.yml" "$DISPATCHER"
	assert_success
}
