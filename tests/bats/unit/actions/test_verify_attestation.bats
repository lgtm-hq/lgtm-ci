#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/verify-attestation.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/verify-attestation.sh"

setup() {
	setup_temp_dir
	setup_github_env

	TARGET_FILE="${BATS_TEST_TMPDIR}/artifact.tar.gz"
	echo "data" >"$TARGET_FILE"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "verify-attestation: fails without STEP" {
	run env -u STEP bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "verify-attestation: fails on unknown step" {
	STEP="bogus" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown step"
}

@test "verify-attestation: verify fails without OWNER" {
	STEP="verify" TARGET="$TARGET_FILE" OWNER="" GITHUB_REPOSITORY_OWNER="" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "OWNER is required"
}

@test "verify-attestation: verify fails when target file is missing" {
	STEP="verify" TARGET="${BATS_TEST_TMPDIR}/missing.bin" OWNER="test-org" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "File not found"
}

@test "verify-attestation: verify fails on unsupported target type" {
	STEP="verify" TARGET="$TARGET_FILE" TARGET_TYPE="floppy" OWNER="test-org" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unsupported target type"
}

@test "verify-attestation: verify succeeds and parses signer identity" {
	mock_command_record "gh" '[{"verificationResult":{"signature":{"certificate":{"subjectAlternativeName":"https://github.com/test-org/repo/.github/workflows/release.yml@refs/heads/main"}}}}]'

	STEP="verify" TARGET="$TARGET_FILE" OWNER="test-org" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Attestation verified successfully"

	grep -qF -- "attestation verify $TARGET_FILE --owner test-org --format json" \
		"${BATS_TEST_TMPDIR}/mock_calls_gh"

	assert_file_contains "$GITHUB_OUTPUT" "verified=true"
	assert_file_contains "$GITHUB_OUTPUT" "signer-identity=https://github.com/test-org/repo"
}

@test "verify-attestation: verify passes --repo when REPO is set" {
	mock_command_record "gh" "[]"

	STEP="verify" TARGET="$TARGET_FILE" OWNER="test-org" REPO="test-org/repo" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	grep -qF -- "--repo test-org/repo" "${BATS_TEST_TMPDIR}/mock_calls_gh"
}

@test "verify-attestation: verify propagates gh failure" {
	mock_command_record "gh" "verification failed" 1

	STEP="verify" TARGET="$TARGET_FILE" OWNER="test-org" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Attestation verification failed"
	assert_file_contains "$GITHUB_OUTPUT" "verified=false"
}

@test "verify-attestation: parse warns when verification output is missing" {
	STEP="parse" VERIFICATION_OUTPUT="${BATS_TEST_TMPDIR}/missing.json" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Verification output not found"
}

@test "verify-attestation: parse prints attestation details" {
	local verification="${BATS_TEST_TMPDIR}/verification.json"
	cat >"$verification" <<'EOF'
[{"verificationResult":{"statement":{"subject":[{"name":"artifact.tar.gz","digest":{"sha256":"abc123"}}],"predicateType":"https://slsa.dev/provenance/v1"},"signature":{"certificate":{"subjectAlternativeName":"https://github.com/test-org"}}}}]
EOF

	STEP="parse" VERIFICATION_OUTPUT="$verification" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Subject: artifact.tar.gz"
	assert_output --partial "Digest: abc123"
}

@test "verify-attestation: summary reports verified state" {
	STEP="summary" VERIFIED="true" TARGET="artifact.tar.gz" \
		SIGNER_IDENTITY="https://github.com/test-org" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "Attestation Verified"
	assert_output --partial "https://github.com/test-org"
}

@test "verify-attestation: summary reports failed state" {
	STEP="summary" VERIFIED="false" TARGET="artifact.tar.gz" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "Attestation Verification Failed"
}
