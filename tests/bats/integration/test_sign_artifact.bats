#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for sign-artifact action script

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/sign-artifact.sh"

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
# Helper: create a mock cosign that produces .sig and .pem files
# =============================================================================
_mock_cosign() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/cosign" <<'MOCK'
#!/usr/bin/env bash
# Mock cosign that creates .sig and .pem files at the requested output paths
sig_file=""
cert_file=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--output-signature) sig_file="$2"; shift 2;;
		--output-certificate) cert_file="$2"; shift 2;;
		*) shift;;
	esac
done
if [[ -n "$sig_file" ]]; then
	echo "MEUCIQDfake-signature-data" > "$sig_file"
fi
if [[ -n "$cert_file" ]]; then
	echo "-----BEGIN CERTIFICATE-----" > "$cert_file"
	echo "MIIBfake-certificate-data" >> "$cert_file"
	echo "-----END CERTIFICATE-----" >> "$cert_file"
fi
exit 0
MOCK
	chmod +x "${mock_bin}/cosign"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# =============================================================================
# STEP validation tests
# =============================================================================

@test "sign-artifact: fails when STEP is not set" {
	run bash -c 'unset STEP; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "STEP is required"
}

@test "sign-artifact: fails on unknown STEP" {
	run bash -c 'export STEP=invalid; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "Unknown step"
}

# =============================================================================
# STEP=sign tests
# =============================================================================

@test "sign-artifact: sign fails when FILES is not set" {
	run bash -c 'export STEP=sign; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "FILES is required"
}

@test "sign-artifact: sign fails when no files match glob" {
	_mock_cosign

	run bash -c '
		export STEP=sign
		export FILES="/nonexistent/path/*.xyz"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "No files matched"
}

@test "sign-artifact: sign fails when cosign not found" {
	# Ensure cosign is not in PATH — only bash itself
	local test_file="${BATS_TEST_TMPDIR}/artifact.tar.gz"
	echo "test content" >"$test_file"

	run bash -c '
		export PATH="/usr/bin:/bin"
		export STEP=sign
		export FILES="'"$test_file"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "cosign not found"
}

@test "sign-artifact: sign succeeds with single file" {
	_mock_cosign

	local test_file="${BATS_TEST_TMPDIR}/artifact.tar.gz"
	echo "test content" >"$test_file"

	run bash -c '
		export STEP=sign
		export FILES="'"$test_file"'"
		export SIGNATURES_DIR="'"${BATS_TEST_TMPDIR}/sigs"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Signed: artifact.tar.gz"
	assert_output --partial "Successfully signed 1 file(s)"

	# Verify outputs were set
	assert_github_output "signed-count" "1"
	assert_github_output "signatures-dir" "${BATS_TEST_TMPDIR}/sigs"

	# Verify signature files were created (sanitized path replaces / with __)
	local sanitized
	sanitized="$(echo "$test_file" | sed 's|^/||; s|/|__|g')"
	assert_file_exists "${BATS_TEST_TMPDIR}/sigs/${sanitized}.sig"
	assert_file_exists "${BATS_TEST_TMPDIR}/sigs/${sanitized}.pem"
}

@test "sign-artifact: sign succeeds with multiple files" {
	_mock_cosign

	local file1="${BATS_TEST_TMPDIR}/app-linux.tar.gz"
	local file2="${BATS_TEST_TMPDIR}/app-darwin.tar.gz"
	echo "linux binary" >"$file1"
	echo "darwin binary" >"$file2"

	run bash -c '
		export STEP=sign
		export FILES="'"${BATS_TEST_TMPDIR}"'/app-*.tar.gz"
		export SIGNATURES_DIR="'"${BATS_TEST_TMPDIR}/sigs"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Successfully signed 2 file(s)"
	assert_github_output "signed-count" "2"

	# Verify all signature files (sanitized path replaces / with __)
	local san1 san2
	san1="$(echo "$file1" | sed 's|^/||; s|/|__|g')"
	san2="$(echo "$file2" | sed 's|^/||; s|/|__|g')"
	assert_file_exists "${BATS_TEST_TMPDIR}/sigs/${san1}.sig"
	assert_file_exists "${BATS_TEST_TMPDIR}/sigs/${san1}.pem"
	assert_file_exists "${BATS_TEST_TMPDIR}/sigs/${san2}.sig"
	assert_file_exists "${BATS_TEST_TMPDIR}/sigs/${san2}.pem"
}

# =============================================================================
# STEP=upload-release tests
# =============================================================================

@test "sign-artifact: upload-release fails without RELEASE_TAG" {
	run bash -c '
		export STEP=upload-release
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "RELEASE_TAG is required"
}

@test "sign-artifact: upload-release calls gh release upload" {
	# Create mock signatures directory
	local sig_dir="${BATS_TEST_TMPDIR}/cosign-signatures"
	mkdir -p "$sig_dir"
	echo "sig-data" >"${sig_dir}/app.tar.gz.sig"
	echo "cert-data" >"${sig_dir}/app.tar.gz.pem"

	mock_command_record "gh" "uploaded"

	run bash -c '
		export STEP=upload-release
		export RELEASE_TAG=v1.0.0
		export SIGNATURES_DIR="'"$sig_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Signatures uploaded to release v1.0.0"

	# Verify gh was called with correct args
	assert_file_exists "${BATS_TEST_TMPDIR}/mock_calls_gh"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output --partial "release upload v1.0.0"
	assert_output --partial "--clobber"
}

# =============================================================================
# STEP=summary tests
# =============================================================================

@test "sign-artifact: summary generates markdown output" {
	run bash -c '
		export STEP=summary
		export SIGNED_COUNT=2
		export FILES="dist/*.tar.gz"
		export CERTIFICATE="/tmp/sigs/app.tar.gz.pem"
		export SIGNATURES="/tmp/sigs/app-linux.tar.gz.sig
/tmp/sigs/app-darwin.tar.gz.sig"
		bash "$SCRIPT" 2>&1
	'
	assert_success

	# Verify summary was written
	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"Artifact Signing Summary"* ]]
	[[ "$summary" == *"2 artifact(s) signed"* ]]
	[[ "$summary" == *"dist/*.tar.gz"* ]]
	[[ "$summary" == *"Sigstore Cosign"* ]]
}

@test "sign-artifact: summary handles zero signed count" {
	run bash -c '
		export STEP=summary
		export SIGNED_COUNT=0
		export FILES="dist/*.tar.gz"
		bash "$SCRIPT" 2>&1
	'
	assert_success

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"No artifacts signed"* ]]
}
