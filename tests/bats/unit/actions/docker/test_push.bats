#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/push.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/push.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	unset TAGS || true
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

@test "push.sh: pushes newline-separated tags" {
	export TAGS=$'ghcr.io/org/repo:main\nghcr.io/org/repo:sha-abc'
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Push completed"
	run grep -Fx "push ghcr.io/org/repo:main" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -Fx "push ghcr.io/org/repo:sha-abc" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "push.sh: pushes comma-separated tags and skips blanks" {
	export TAGS="ghcr.io/org/repo:a, ,ghcr.io/org/repo:b"
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_success
	run grep -Fx "push ghcr.io/org/repo:a" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -Fx "push ghcr.io/org/repo:b" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	# Only two push lines
	run bash -c "grep -c '^push ' '${BATS_TEST_TMPDIR}/mock_calls_docker'"
	assert_output "2"
}

@test "push.sh: succeeds with empty TAGS (no pushes)" {
	export TAGS=""
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_success
	run grep -F "push " "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_failure
}
