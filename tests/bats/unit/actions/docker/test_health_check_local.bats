#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/health-check-local.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"
load "../../../../helpers/health_mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/health-check-local.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export IMAGE="ghcr.io/org/repo:local"
	export HEALTH_CHECK_CMD="true"
	export HEALTH_CHECK_PORT="8080"
	export HEALTH_CHECK_TIMEOUT="5s"
	unset PLATFORM || true
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

@test "health-check-local.sh: runs health check against local image" {
	_install_health_mocks

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Health check passed"
	run grep -F "run -d -p 127.0.0.1:8080:8080 ghcr.io/org/repo:local" \
		"${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "health-check-local.sh: requires IMAGE" {
	unset IMAGE || true
	_install_health_mocks

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "IMAGE is required"
}

@test "health-check-local.sh: requires HEALTH_CHECK_PORT" {
	unset HEALTH_CHECK_PORT || true
	_install_health_mocks

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "HEALTH_CHECK_PORT is required"
}

@test "health-check-local.sh: requires HEALTH_CHECK_CMD" {
	unset HEALTH_CHECK_CMD || true
	_install_health_mocks

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "HEALTH_CHECK_CMD is required"
}
