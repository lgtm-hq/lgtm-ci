#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-ghcr-cleanup workflow inputs and job shape

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-ghcr-cleanup.yml"

@test "reusable-ghcr-cleanup: keep-latest defaults to 0" {
	run awk '/^      keep-latest:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "default: 0"
}

@test "reusable-ghcr-cleanup: build-cache-pr-age-days defaults to 14" {
	run awk '/^      build-cache-pr-age-days:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "default: 14"
}

@test "reusable-ghcr-cleanup: protect-referenced defaults to true" {
	run awk '/^      protect-referenced:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "default: true"
}

@test "reusable-ghcr-cleanup: passes build-cache and protection env vars" {
	run awk '
		/- name: Clean untagged GHCR images/ { step = 1 }
		step && /BUILD_CACHE_PR_AGE_DAYS:/ { buildcache = 1 }
		step && /PROTECT_REFERENCED:/ { protect = 1 }
		step && /PRUNE_BUILDCACHE:/ { prune = 1 }
		END { exit !(buildcache && protect && prune) }
	' "$WORKFLOW"
	assert_success
}
