#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/trivy-sarif.sh (#1081)

load "../../../../helpers/common"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/trivy-sarif.sh"
NAME="trivy-results-linux-amd64.sarif"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "trivy-sarif.sh: requires MODE and SARIF_NAME" {
	run env -u MODE SARIF_NAME="$NAME" bash "$SCRIPT"
	assert_failure
	assert_output --partial "MODE is required"
	run env -u SARIF_NAME MODE=stage bash "$SCRIPT"
	assert_failure
	assert_output --partial "SARIF_NAME is required"
}

@test "trivy-sarif.sh: rejects an unknown MODE" {
	run env MODE=upload SARIF_NAME="$NAME" bash "$SCRIPT"
	[ "$status" -eq 2 ]
	assert_output --partial "MODE must be stage or locate"
}

@test "trivy-sarif.sh: stage copies an existing SARIF" {
	local sarif="${BATS_TEST_TMPDIR}/${NAME}" stage="${BATS_TEST_TMPDIR}/stage"
	printf '{"runs":[]}\n' >"$sarif"
	run env MODE=stage SARIF_NAME="$NAME" SARIF_FILE="$sarif" STAGE_DIR="$stage" bash "$SCRIPT"
	assert_success
	[ -s "${stage}/${NAME}" ]
	[ ! -e "${stage}/no-sarif.txt" ]
}

@test "trivy-sarif.sh: stage writes the marker when Trivy produced nothing" {
	local stage="${BATS_TEST_TMPDIR}/stage"
	run env MODE=stage SARIF_NAME="$NAME" SARIF_FILE="${BATS_TEST_TMPDIR}/missing.sarif" \
		STAGE_DIR="$stage" bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::No SARIF"
	[ -f "${stage}/no-sarif.txt" ]
	[ ! -e "${stage}/${NAME}" ]
}

@test "trivy-sarif.sh: stage treats an empty SARIF as missing" {
	local sarif="${BATS_TEST_TMPDIR}/${NAME}" stage="${BATS_TEST_TMPDIR}/stage"
	: >"$sarif"
	run env MODE=stage SARIF_NAME="$NAME" SARIF_FILE="$sarif" STAGE_DIR="$stage" bash "$SCRIPT"
	assert_success
	[ -f "${stage}/no-sarif.txt" ]
	[ ! -e "${stage}/${NAME}" ]
}

@test "trivy-sarif.sh: locate finds the SARIF in the extracted artifact" {
	local dl="${BATS_TEST_TMPDIR}/dl"
	mkdir -p "${dl}/docker-trivy-sarif-linux-amd64"
	printf '{}\n' >"${dl}/docker-trivy-sarif-linux-amd64/${NAME}"
	run env MODE=locate SARIF_NAME="$NAME" DOWNLOAD_DIR="$dl" bash "$SCRIPT"
	assert_success
	run grep -x "found=true" "$GITHUB_OUTPUT"
	assert_success
	run grep -x "path=${dl}/docker-trivy-sarif-linux-amd64/${NAME}" "$GITHUB_OUTPUT"
	assert_success
}

@test "trivy-sarif.sh: locate skips explicitly on the marker" {
	local dl="${BATS_TEST_TMPDIR}/dl"
	mkdir -p "${dl}/a"
	printf 'x\n' >"${dl}/a/no-sarif.txt"
	run env MODE=locate SARIF_NAME="$NAME" DOWNLOAD_DIR="$dl" bash "$SCRIPT"
	assert_success
	assert_output --partial "::notice::"
	run grep -x "found=false" "$GITHUB_OUTPUT"
	assert_success
}

@test "trivy-sarif.sh: locate fails when the artifact holds neither file" {
	local dl="${BATS_TEST_TMPDIR}/dl"
	mkdir -p "${dl}/a"
	run env MODE=locate SARIF_NAME="$NAME" DOWNLOAD_DIR="$dl" bash "$SCRIPT"
	assert_failure
	assert_output --partial "Neither ${NAME} nor no-sarif.txt"
}
