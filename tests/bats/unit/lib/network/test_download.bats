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

@test "download_with_retries: enforces HTTPS-only and TLS 1.2 floor" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--proto =https"
	assert_output --partial "--tlsv1.2"
}

@test "download_with_retries: passes pinned pubkey from env" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && LGTM_CI_PINNED_PUBKEY="sha256//AAAA" download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey sha256//AAAA"
}

@test "download_with_retries: no pinning args by default" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	refute_output --partial "--pinnedpubkey"
	refute_output --partial "--cacert"
}

@test "download_with_retries: passes custom CA bundle from env" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	local bundle="${BATS_TEST_TMPDIR}/ca.pem"
	echo "fake-ca" >"$bundle"
	run bash -c "source \"\$LIB_DIR/network/download.sh\" && LGTM_CI_CA_BUNDLE=\"$bundle\" download_with_retries \"https://example.com/file\" \"\$BATS_TEST_TMPDIR/out\""
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--cacert ${bundle}"
}

@test "download_with_retries: fails closed on unreadable CA bundle" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && LGTM_CI_CA_BUNDLE="/nonexistent/ca.pem" download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out" 2>&1'
	assert_failure
	assert_output --partial "CA bundle not readable"
	# curl must never be invoked
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output ""
}

# =============================================================================
# download_with_pinning tests
# =============================================================================

@test "download_with_pinning: succeeds with explicit hash pin" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "pinned content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out" "sha256//BBBB"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey sha256//BBBB"
	run cat "${BATS_TEST_TMPDIR}/out"
	assert_output "pinned content"
}

@test "download_with_pinning: accepts pin from LGTM_CI_PINNED_PUBKEY env" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && LGTM_CI_PINNED_PUBKEY="sha256//CCCC" download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey sha256//CCCC"
}

@test "download_with_pinning: fails closed without a pin" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out" 2>&1'
	assert_failure
	assert_output --partial "refusing unpinned download"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output ""
}

@test "download_with_pinning: fails closed on unreadable pin key file" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out" "/nonexistent/pin.pem" 2>&1'
	assert_failure
	assert_output --partial "pinned key file not readable"
}

@test "download_with_pinning: accepts pin key file path and CA bundle" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	local pin="${BATS_TEST_TMPDIR}/pin.pem"
	local bundle="${BATS_TEST_TMPDIR}/ca.pem"
	echo "fake-key" >"$pin"
	echo "fake-ca" >"$bundle"
	run bash -c "source \"\$LIB_DIR/network/download.sh\" && download_with_pinning \"https://example.com/file\" \"\$BATS_TEST_TMPDIR/out\" \"$pin\" \"$bundle\""
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey ${pin}"
	assert_output --partial "--cacert ${bundle}"
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

@test "download_and_run_installer: enforces HTTPS-only and TLS 1.2 floor" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_installer_script 'echo "installer ran"'
	# Wrap the mock curl to record args (mock_curl_installer_script does not)
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mv "${mock_bin}/curl" "${mock_bin}/curl.real"
	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_curl'
exec '${mock_bin}/curl.real' "\$@"
EOF
	chmod +x "${mock_bin}/curl"

	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "https://example.com/install.sh"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--proto =https"
	assert_output --partial "--tlsv1.2"
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

@test "download.sh: declares download_with_pinning function" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/network/download.sh" && declare -f download_with_pinning >/dev/null && echo "declared"'
	assert_success
	assert_output "declared"
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
