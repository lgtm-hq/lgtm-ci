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

@test "reusable-ghcr-cleanup: prune-tagged defaults to false so existing consumers are unaffected" {
	run awk '/^      prune-tagged:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "default: false"
}

@test "reusable-ghcr-cleanup: main-retention-days defaults to 30" {
	run awk '/^      main-retention-days:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "default: 30"
}

@test "reusable-ghcr-cleanup: prerelease-retention-days defaults to 90" {
	run awk '/^      prerelease-retention-days:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "default: 90"
}

@test "reusable-ghcr-cleanup: tagged prune step is gated on prune-tagged and reuses dry-run" {
	run awk '
		/- name: Prune aged tagged GHCR images/ { step = 1; next }
		step && /^      - name:/ { exit }
		step && /if: \$\{\{ inputs.prune-tagged \}\}/ { gated = 1 }
		step && /MAIN_RETENTION_DAYS: \$\{\{ inputs.main-retention-days \}\}/ { main = 1 }
		step && /PRERELEASE_RETENTION_DAYS: \$\{\{ inputs.prerelease-retention-days \}\}/ { pre = 1 }
		step && /DRY_RUN: \$\{\{ inputs.dry-run \}\}/ { dry = 1 }
		# Auth and target: the script hard-fails without these, and miswiring
		# them would point a destructive run at the wrong package or identity.
		step && /GH_TOKEN: \$\{\{ secrets.token \}\}/ { token = 1 }
		step && /PACKAGE_NAME: \$\{\{ inputs.package-name \}\}/ { package = 1 }
		step && /GITHUB_ORG: \$\{\{ github.repository_owner \}\}/ { org = 1 }
		step && /ghcr-prune-tags.sh/ { script = 1 }
		END { exit !(gated && main && pre && dry && token && package && org && script) }
	' "$WORKFLOW"
	assert_success
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
