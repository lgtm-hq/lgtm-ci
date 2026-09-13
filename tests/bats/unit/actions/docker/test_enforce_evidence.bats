#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/docker/enforce-evidence.sh (#963)

load "../../../../helpers/common"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/build-docker.sh"

setup() {
	setup_temp_dir
	setup_github_env
	export STEP="enforce-evidence"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "enforce-evidence: warns for each opted-out input on a push" {
	PUSH=true PROVENANCE=false SBOM=false run bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning title=provenance enforced on push::"
	assert_output --partial "::warning title=sbom enforced on push::"
	assert_output --partial "release-security policy"
}

@test "enforce-evidence: warns only for the input that opted out" {
	PUSH=true PROVENANCE=true SBOM=false run bash "$SCRIPT"
	assert_success
	refute_output --partial "provenance enforced"
	assert_output --partial "sbom enforced on push"
}

@test "enforce-evidence: stays silent for a non-push build" {
	PUSH=false PROVENANCE=false SBOM=false run bash "$SCRIPT"
	assert_success
	refute_output --partial "::warning"
	assert_output --partial "honoured as given"
}

@test "enforce-evidence: requires PUSH" {
	run bash -c 'unset PUSH; STEP=enforce-evidence bash "$1"' _ "$SCRIPT"
	assert_failure
	assert_output --partial "PUSH is required"
}
