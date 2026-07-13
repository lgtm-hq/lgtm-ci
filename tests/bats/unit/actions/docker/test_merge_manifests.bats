#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/merge-manifests.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/merge-manifests.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export RUN_ID="99"
	export MATRIX='[{"platform":"linux/amd64","slug":"linux-amd64"},{"platform":"linux/arm64","slug":"linux-arm64"}]'
	export TARGET_TAGS=$'ghcr.io/org/repo:main\nghcr.io/org/repo:sha-abc'
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

setup_file() {
	if ! command -v jq >/dev/null 2>&1; then
		skip "jq not available — required by merge-manifests.sh"
	fi
}

@test "merge-manifests.sh: creates multi-arch manifest from staging tags" {
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Multi-arch manifest created"

	local calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	run grep -F -- "buildx imagetools create" "$calls"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:main" "$calls"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:sha-abc" "$calls"
	assert_success
	run grep -F -- "ghcr.io/org/repo:build-99-linux-amd64" "$calls"
	assert_success
	run grep -F -- "ghcr.io/org/repo:build-99-linux-arm64" "$calls"
	assert_success
}

@test "merge-manifests.sh: fails when TARGET_TAGS is whitespace only" {
	export TARGET_TAGS=$'  \n\t'
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "No valid tags found in TARGET_TAGS"
}

@test "merge-manifests.sh: fails when MATRIX is unset" {
	unset MATRIX || true
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "MATRIX is required"
}
