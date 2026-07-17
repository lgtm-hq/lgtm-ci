#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/upload-sbom-release-assets.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/upload-sbom-release-assets.sh"

setup() {
	setup_temp_dir
	export GH_TOKEN="test-token"
	export RELEASE_TAG="v1.2.3"
	export ARTIFACT_NAME="sbom"
	export SBOM_ARTIFACT_DIR="${BATS_TEST_TMPDIR}/sbom-artifact"
	mkdir -p "${SBOM_ARTIFACT_DIR}"
}

teardown() {
	teardown_temp_dir
}

@test "upload-sbom-release-assets.sh: fails without GH_TOKEN" {
	run env -u GH_TOKEN bash "$SCRIPT"
	assert_failure
	assert_output --partial "GH_TOKEN is required"
}

@test "upload-sbom-release-assets.sh: fails when artifact dir missing" {
	run env SBOM_ARTIFACT_DIR="${BATS_TEST_TMPDIR}/missing" bash "$SCRIPT"
	assert_failure
	assert_output --partial "SBOM artifact directory not found"
}

@test "upload-sbom-release-assets.sh: fails when no files present" {
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "No SBOM files found in downloaded artifact 'sbom'"
}

@test "upload-sbom-release-assets.sh: uploads sorted files via gh" {
	printf 'a' >"${SBOM_ARTIFACT_DIR}/b.json"
	printf 'b' >"${SBOM_ARTIFACT_DIR}/a.json"
	mkdir -p "${SBOM_ARTIFACT_DIR}/nested"
	printf 'c' >"${SBOM_ARTIFACT_DIR}/nested/c.json"
	# Hidden files must be ignored
	printf 'x' >"${SBOM_ARTIFACT_DIR}/.hidden"

	mock_command_record "gh" "uploaded"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Uploaded 3 SBOM file(s) to release v1.2.3"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
	assert_output --partial "release upload v1.2.3"
	assert_output --partial "--clobber"
	assert_output --partial "${SBOM_ARTIFACT_DIR}/a.json"
	assert_output --partial "${SBOM_ARTIFACT_DIR}/b.json"
	assert_output --partial "${SBOM_ARTIFACT_DIR}/nested/c.json"
}
