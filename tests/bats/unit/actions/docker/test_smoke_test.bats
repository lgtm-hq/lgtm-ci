#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/smoke-test.sh (LOCAL=true/false)

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/smoke-test.sh"
VALID_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	unset SMOKE_TEST SMOKE_TEST_SCRIPT LOCAL || true
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_write_digest_file() {
	export DIGEST_FILE="${BATS_TEST_TMPDIR}/digest.txt"
	printf '%s' "$VALID_DIGEST" >"$DIGEST_FILE"
}

# =============================================================================
# LOCAL=false (registry pull by digest)
# =============================================================================

@test "smoke-test: pulls by digest and runs command when LOCAL=false" {
	export LOCAL="false"
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export PLATFORM="linux/amd64"
	export SMOKE_TEST="--version"
	_write_digest_file
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_success

	local calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	run grep "pull --platform linux/amd64 ghcr.io/org/repo@${VALID_DIGEST}" "$calls"
	assert_success
	run grep -- "run --rm --platform linux/amd64 ghcr.io/org/repo@${VALID_DIGEST} --version" "$calls"
	assert_success
}

@test "smoke-test: defaults to LOCAL=false when LOCAL is unset" {
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export PLATFORM="linux/amd64"
	export SMOKE_TEST="--version"
	_write_digest_file
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_success

	run grep "pull " "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "smoke-test: fails when DIGEST_FILE is missing (LOCAL=false)" {
	export LOCAL="false"
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export PLATFORM="linux/amd64"
	export SMOKE_TEST="--version"
	export DIGEST_FILE="${BATS_TEST_TMPDIR}/does-not-exist.txt"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST_FILE missing or empty"
}

@test "smoke-test: fails on invalid digest (LOCAL=false)" {
	export LOCAL="false"
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export PLATFORM="linux/amd64"
	export SMOKE_TEST="--version"
	export DIGEST_FILE="${BATS_TEST_TMPDIR}/digest.txt"
	printf '%s' "not-a-digest" >"$DIGEST_FILE"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Invalid digest"
}

@test "smoke-test: fails when IMAGE_NAME is unset (LOCAL=false)" {
	export LOCAL="false"
	export REGISTRY="ghcr.io"
	export PLATFORM="linux/amd64"
	export SMOKE_TEST="--version"
	unset IMAGE_NAME
	_write_digest_file

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "IMAGE_NAME"
}

# =============================================================================
# LOCAL=true (locally loaded image, no pull)
# =============================================================================

@test "smoke-test: runs command without pulling when LOCAL=true" {
	export LOCAL="true"
	export IMAGE="ghcr.io/org/repo:sha-abc123"
	export PLATFORM="linux/amd64"
	export REGISTRY="ghcr.io"
	export SMOKE_TEST="--version"
	mock_command_record "docker"

	run bash "$SCRIPT"
	assert_success

	local calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	run grep "pull " "$calls"
	assert_failure
	run grep -- "run --rm --platform linux/amd64 ghcr.io/org/repo:sha-abc123 --version" "$calls"
	assert_success
}

@test "smoke-test: fails when IMAGE is unset (LOCAL=true)" {
	export LOCAL="true"
	export PLATFORM="linux/amd64"
	export REGISTRY="ghcr.io"
	export SMOKE_TEST="--version"
	unset IMAGE

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "IMAGE"
}

@test "smoke-test: runs caller-owned script with IMAGE exported (LOCAL=true)" {
	export LOCAL="true"
	export IMAGE="ghcr.io/org/repo:sha-abc123"
	export PLATFORM="linux/amd64"
	export REGISTRY="ghcr.io"
	export SMOKE_TEST_SCRIPT="smoke.sh"
	mock_command_record "docker"

	cd "$BATS_TEST_TMPDIR"
	cat >smoke.sh <<'EOF'
#!/usr/bin/env bash
echo "smoke script saw IMAGE=${IMAGE} PLATFORM=${PLATFORM}"
EOF

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "smoke script saw IMAGE=ghcr.io/org/repo:sha-abc123 PLATFORM=linux/amd64"
}

@test "smoke-test: fails when smoke-test-script does not exist (LOCAL=true)" {
	export LOCAL="true"
	export IMAGE="ghcr.io/org/repo:sha-abc123"
	export PLATFORM="linux/amd64"
	export REGISTRY="ghcr.io"
	export SMOKE_TEST_SCRIPT="${BATS_TEST_TMPDIR}/missing.sh"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "smoke-test-script not found"
}

# =============================================================================
# Shared validation (both modes)
# =============================================================================

@test "smoke-test: fails when SMOKE_TEST and SMOKE_TEST_SCRIPT both set" {
	export LOCAL="true"
	export IMAGE="ghcr.io/org/repo:sha-abc123"
	export PLATFORM="linux/amd64"
	export REGISTRY="ghcr.io"
	export SMOKE_TEST="--version"
	export SMOKE_TEST_SCRIPT="smoke.sh"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "mutually exclusive"
}

@test "smoke-test: fails when neither SMOKE_TEST nor SMOKE_TEST_SCRIPT set" {
	export LOCAL="false"
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export PLATFORM="linux/amd64"
	_write_digest_file

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "One of SMOKE_TEST or SMOKE_TEST_SCRIPT is required"
}
