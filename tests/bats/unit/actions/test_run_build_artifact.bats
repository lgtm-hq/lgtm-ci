#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-build-artifact.sh (#522)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-build-artifact.sh"

setup() {
	setup_temp_dir
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
}

teardown() {
	teardown_temp_dir
}

@test "run-build-artifact: executes build-command" {
	run env \
		WORKING_DIRECTORY="$WORK_DIR" \
		BUILD_COMMAND='mkdir -p dist && echo built > dist/out.txt' \
		ARTIFACT_PATH="dist" \
		POST_BUILD_TEST_COMMAND="" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Running build command"
	assert_file_exists "${WORK_DIR}/dist/out.txt"
	assert_output --partial "Artifact path ready: dist"
}

@test "run-build-artifact: runs post-build-test-command when set" {
	run env \
		WORKING_DIRECTORY="$WORK_DIR" \
		BUILD_COMMAND='mkdir -p dist && echo built > dist/out.txt' \
		ARTIFACT_PATH="dist" \
		POST_BUILD_TEST_COMMAND='echo post-test-ok > post.txt' \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Running post-build test command"
	assert_file_exists "${WORK_DIR}/post.txt"
	assert_file_contains "${WORK_DIR}/post.txt" "post-test-ok"
}

@test "run-build-artifact: skips post-build-test-command when empty" {
	run env \
		WORKING_DIRECTORY="$WORK_DIR" \
		BUILD_COMMAND='mkdir -p dist && echo built > dist/out.txt' \
		ARTIFACT_PATH="dist" \
		POST_BUILD_TEST_COMMAND="" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "No post-build-test-command set; skipping"
	assert_file_not_exists "${WORK_DIR}/post.txt"
}

@test "run-build-artifact: fails when artifact-path missing after build" {
	run env \
		WORKING_DIRECTORY="$WORK_DIR" \
		BUILD_COMMAND='echo no-artifact' \
		ARTIFACT_PATH="dist" \
		POST_BUILD_TEST_COMMAND="" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "artifact-path does not exist after build: dist"
}

@test "run-build-artifact: fails when post-build-test-command fails" {
	run env \
		WORKING_DIRECTORY="$WORK_DIR" \
		BUILD_COMMAND='mkdir -p dist && echo built > dist/out.txt' \
		ARTIFACT_PATH="dist" \
		POST_BUILD_TEST_COMMAND='exit 7' \
		bash "$SCRIPT"

	assert_failure
	assert_equal "7" "$status"
}

@test "run-build-artifact: fails when working directory missing" {
	run env \
		WORKING_DIRECTORY="${WORK_DIR}/missing" \
		BUILD_COMMAND='echo hi' \
		ARTIFACT_PATH="dist" \
		POST_BUILD_TEST_COMMAND="" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "Working directory does not exist"
}
