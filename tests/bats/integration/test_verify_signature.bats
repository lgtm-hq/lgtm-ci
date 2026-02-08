#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for verify-signature action script

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/verify-signature.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# Helper: create mock cosign for verification
# =============================================================================
_mock_cosign_verify() {
	local exit_code="${1:-0}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/cosign" <<MOCK
#!/usr/bin/env bash
echo "Verified OK"
exit $exit_code
MOCK
	chmod +x "${mock_bin}/cosign"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# =============================================================================
# Helper: create test files for verification
# =============================================================================
_setup_verify_files() {
	export TEST_FILE="${BATS_TEST_TMPDIR}/artifact.tar.gz"
	export TEST_SIG="${BATS_TEST_TMPDIR}/artifact.tar.gz.sig"
	export TEST_CERT="${BATS_TEST_TMPDIR}/artifact.tar.gz.pem"

	echo "test content" >"$TEST_FILE"
	echo "MEUCIQDfake-signature-data" >"$TEST_SIG"
	echo "-----BEGIN CERTIFICATE-----" >"$TEST_CERT"
}

# =============================================================================
# STEP validation tests
# =============================================================================

@test "verify-signature: fails when STEP is not set" {
	run bash -c 'unset STEP; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "STEP is required"
}

@test "verify-signature: fails on unknown STEP" {
	run bash -c 'export STEP=invalid; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "Unknown step"
}

# =============================================================================
# STEP=verify tests
# =============================================================================

@test "verify-signature: verify fails when required vars missing" {
	run bash -c '
		export STEP=verify
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "FILE is required"
}

@test "verify-signature: verify fails when cosign not found" {
	_setup_verify_files

	run bash -c '
		export PATH="/usr/bin:/bin"
		export STEP=verify
		export FILE="'"$TEST_FILE"'"
		export SIGNATURE="'"$TEST_SIG"'"
		export CERTIFICATE="'"$TEST_CERT"'"
		export CERTIFICATE_IDENTITY="https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
		export CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "cosign not found"
}

@test "verify-signature: verify fails when file not found" {
	_mock_cosign_verify

	run bash -c '
		export STEP=verify
		export FILE="/nonexistent/file.tar.gz"
		export SIGNATURE="/some/file.sig"
		export CERTIFICATE="/some/file.pem"
		export CERTIFICATE_IDENTITY="https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
		export CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "File not found"
}

@test "verify-signature: verify fails when signature not found" {
	_mock_cosign_verify
	_setup_verify_files

	run bash -c '
		export STEP=verify
		export FILE="'"$TEST_FILE"'"
		export SIGNATURE="/nonexistent/file.sig"
		export CERTIFICATE="'"$TEST_CERT"'"
		export CERTIFICATE_IDENTITY="https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
		export CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "Signature file not found"
}

@test "verify-signature: successful verification" {
	_mock_cosign_verify 0
	_setup_verify_files

	run bash -c '
		export STEP=verify
		export FILE="'"$TEST_FILE"'"
		export SIGNATURE="'"$TEST_SIG"'"
		export CERTIFICATE="'"$TEST_CERT"'"
		export CERTIFICATE_IDENTITY="https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
		export CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Signature verified successfully"
	assert_github_output "verified" "true"
}

@test "verify-signature: failed verification" {
	_mock_cosign_verify 1
	_setup_verify_files

	run bash -c '
		export STEP=verify
		export FILE="'"$TEST_FILE"'"
		export SIGNATURE="'"$TEST_SIG"'"
		export CERTIFICATE="'"$TEST_CERT"'"
		export CERTIFICATE_IDENTITY="https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
		export CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "Signature verification failed"
	assert_github_output "verified" "false"
}

# =============================================================================
# STEP=summary tests
# =============================================================================

@test "verify-signature: summary with successful verification" {
	run bash -c '
		export STEP=summary
		export VERIFIED=true
		export FILE="dist/app.tar.gz"
		export SIGNATURE="dist/app.tar.gz.sig"
		export CERTIFICATE_IDENTITY="https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
		bash "$SCRIPT" 2>&1
	'
	assert_success

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"Signature Verification Summary"* ]]
	[[ "$summary" == *"Signature Verified"* ]]
	[[ "$summary" == *"dist/app.tar.gz"* ]]
	[[ "$summary" == *"Signer Identity"* ]]
}

@test "verify-signature: summary with failed verification" {
	run bash -c '
		export STEP=summary
		export VERIFIED=false
		export FILE="dist/app.tar.gz"
		export SIGNATURE="dist/app.tar.gz.sig"
		bash "$SCRIPT" 2>&1
	'
	assert_success

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"Signature Verification Failed"* ]]
}
