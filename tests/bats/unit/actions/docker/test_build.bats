#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/build.sh (per-step edge cases)

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/build.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export IMAGE_NAME="org/repo"
	export REGISTRY="ghcr.io"
	export CONTEXT="."
	export FILE="Dockerfile"
	export PLATFORMS="linux/amd64,linux/arm64"
	export PUSH="false"
	export LOAD="false"
	unset TAGS VERSION BUILD_ARGS LABELS CACHE_FROM CACHE_TO || true
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_mock_docker_buildx() {
	local exit_code="${1:-0}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_docker"
	mkdir -p "$mock_bin"
	: >"$calls_file"

	cat >"${mock_bin}/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> '${calls_file}'
exit ${exit_code}
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:$PATH"
}

@test "build.sh: fails when IMAGE_NAME is unset" {
	unset IMAGE_NAME GITHUB_REPOSITORY || true
	_mock_docker_buildx

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "IMAGE_NAME is required"
}

@test "build.sh: succeeds and sets exit-code/tags outputs" {
	_mock_docker_buildx

	run bash "$SCRIPT"
	assert_success
	assert_github_output "exit-code" "0"
	assert_output --partial "Build completed successfully"

	# SHA + branch tags from github_env defaults
	run grep -F -- "buildx build" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--platform linux/amd64,linux/arm64" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:sha-abc1234" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:main" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "build.sh: omits --platform when LOAD=true" {
	export LOAD="true"
	_mock_docker_buildx

	run bash "$SCRIPT"
	assert_success
	run grep -F -- "--load" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--platform" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_failure
}

@test "build.sh: adds --push when PUSH=true" {
	export PUSH="true"
	_mock_docker_buildx

	run bash "$SCRIPT"
	assert_success
	run grep -F -- "--push" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--load" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_failure
}

@test "build.sh: adds semver and custom tags" {
	export VERSION="1.2.3"
	export TAGS="canary,ghcr.io/org/repo:extra"
	_mock_docker_buildx

	run bash "$SCRIPT"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:1.2.3" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:latest" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:canary" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--tag ghcr.io/org/repo:extra" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "build.sh: redacts build-arg and label values in log" {
	export BUILD_ARGS="SECRET=s3cr3t"
	export LABELS="private=value"
	_mock_docker_buildx

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "--build-arg [REDACTED]"
	assert_output --partial "--label [REDACTED]"
	refute_output --partial "s3cr3t"
	refute_output --partial "private=value"

	# Actual docker invocation still receives real values
	run grep -F -- "--build-arg SECRET=s3cr3t" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--label private=value" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "build.sh: propagates docker failure exit code" {
	_mock_docker_buildx 7

	run bash "$SCRIPT"
	assert_failure
	assert_equal "$status" "7"
	assert_github_output "exit-code" "7"
	assert_output --partial "Build failed with exit code: 7"
}

@test "build.sh: applies cache-from and cache-to" {
	export CACHE_FROM="type=gha"
	export CACHE_TO="type=gha,mode=max"
	_mock_docker_buildx

	run bash "$SCRIPT"
	assert_success
	run grep -F -- "--cache-from type=gha" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
	run grep -F -- "--cache-to type=gha,mode=max" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}
