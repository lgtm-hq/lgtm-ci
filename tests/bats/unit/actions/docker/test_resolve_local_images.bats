#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for resolve-local-scan-image.sh and resolve-local-health-check-image.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

SCAN_SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/resolve-local-scan-image.sh"
HEALTH_SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/resolve-local-health-check-image.sh"

setup() {
	setup_temp_dir
	setup_github_env
	unset TAGS || true
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "resolve-local-scan-image.sh: outputs first tag as ref" {
	export TAGS=$'ghcr.io/org/repo:local\nghcr.io/org/repo:other'

	run bash "$SCAN_SCRIPT"
	assert_success
	assert_github_output "ref" "ghcr.io/org/repo:local"
	assert_output --partial "Local scan image"
}

@test "resolve-local-scan-image.sh: fails when TAGS is empty" {
	export TAGS="   "

	run bash "$SCAN_SCRIPT"
	assert_failure
	assert_output --partial "No image tag available for local Trivy scan"
}

@test "resolve-local-scan-image.sh: requires TAGS" {
	unset TAGS || true

	run bash "$SCAN_SCRIPT"
	assert_failure
	assert_output --partial "TAGS is required"
}

@test "resolve-local-health-check-image.sh: outputs first tag as image" {
	export TAGS=$'ghcr.io/org/repo:health\nghcr.io/org/repo:other'

	run bash "$HEALTH_SCRIPT"
	assert_success
	assert_github_output "image" "ghcr.io/org/repo:health"
	assert_output --partial "Local health-check image"
}

@test "resolve-local-health-check-image.sh: fails when TAGS is empty" {
	export TAGS=$'\n\t'

	run bash "$HEALTH_SCRIPT"
	assert_failure
	assert_output --partial "No image tag available for local health check"
}

@test "resolve-local-health-check-image.sh: requires TAGS" {
	unset TAGS || true

	run bash "$HEALTH_SCRIPT"
	assert_failure
	assert_output --partial "TAGS is required"
}
