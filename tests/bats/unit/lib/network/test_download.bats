#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/network/download.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# download_with_retries tests
# =============================================================================

@test "download_with_retries: succeeds with mock curl" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download "test content"
	local outfile="${BATS_TEST_TMPDIR}/downloaded.txt"
	run bash -c "source \"\$LIB_DIR/network/download.sh\" && download_with_retries \"http://example.com/file\" \"$outfile\""
	assert_success
	[[ -f "$outfile" ]]
	# Verify the mock payload was written correctly
	run cat "$outfile"
	assert_output "test content"
}

@test "download_with_retries: uses default 3 attempts" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	# Create a failing curl mock
	mock_command "curl" "" 1
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_retries "http://example.com/fail" "/tmp/out" 2>&1'
	assert_failure
}

@test "download_with_retries: respects custom attempt count" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_command "curl" "" 1
	# With 1 attempt, should fail faster
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_retries "http://example.com/fail" "/tmp/out" 1 2>&1'
	assert_failure
}

# =============================================================================
# download_and_run_installer tests
# =============================================================================

# Helper: create a mock curl that writes an installer script to -o target
# Usage: mock_curl_installer_script "echo 'hello world'"
mock_curl_installer_script() {
	local script_body="$1"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	# Write the desired script body to a payload file
	local payload="${mock_bin}/.installer_payload"
	printf '#!/usr/bin/env bash\n%s\n' "$script_body" >"$payload"

	cat >"${mock_bin}/curl" <<'CURL'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2;;
        --output) output_file="$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "$output_file" ]]; then
    cp "PAYLOAD_PLACEHOLDER" "$output_file"
fi
exit 0
CURL
	# Patch the placeholder with the real payload path
	sed -i.bak "s|PAYLOAD_PLACEHOLDER|${payload}|" "${mock_bin}/curl"
	rm -f "${mock_bin}/curl.bak"
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"
}

@test "download_and_run_installer: downloads and executes script" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_installer_script 'echo "installer ran"'

	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "http://example.com/install.sh"'
	assert_success
	assert_output --partial "installer ran"
}

@test "download_and_run_installer: passes arguments to script" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_installer_script 'echo "args: $@"'

	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "http://example.com/install.sh" arg1 arg2'
	assert_success
	assert_output --partial "args: arg1 arg2"
}

@test "download_and_run_installer: fails when curl fails" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_command "curl" "" 1
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "http://example.com/fail.sh" 2>&1'
	assert_failure
	assert_output --partial "Failed to download"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "download.sh: exports download_with_retries function" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && bash -c "download_with_retries http://example.com /dev/null"'
	assert_success
}

@test "download.sh: declares download_and_run_installer function" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/network/download.sh" && declare -f download_and_run_installer >/dev/null && echo "declared"'
	assert_success
	assert_output "declared"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "download.sh: can be sourced multiple times without error" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c '
		source "$LIB_DIR/network/download.sh"
		source "$LIB_DIR/network/download.sh"
		source "$LIB_DIR/network/download.sh"
		declare -f download_with_retries >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "download.sh: sets _LGTM_CI_NETWORK_DOWNLOAD_LOADED guard" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/network/download.sh" && echo "${_LGTM_CI_NETWORK_DOWNLOAD_LOADED}"'
	assert_success
	assert_output "1"
}
