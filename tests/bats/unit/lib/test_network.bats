#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/network.sh (aggregator)

load "../../../helpers/common"
load "../../../helpers/mocks"

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
# Aggregator loading tests
# =============================================================================

@test "network.sh: sources port.sh" {
	run bash -c 'source "$LIB_DIR/network.sh" && declare -f port_available >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "network.sh: sources checksum.sh" {
	run bash -c 'source "$LIB_DIR/network.sh" && declare -f verify_checksum >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "network.sh: sources download.sh" {
	run bash -c 'source "$LIB_DIR/network.sh" && declare -f download_with_retries >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Integration tests
# =============================================================================

@test "network.sh: port_available works" {
	run bash -c 'source "$LIB_DIR/network.sh" && port_available 49999 2>/dev/null && echo "available"'
	assert_success
	assert_output "available"
}

@test "network.sh: download_with_retries works" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download "test content"
	local outfile="${BATS_TEST_TMPDIR}/downloaded.txt"
	run bash -c "source \"\$LIB_DIR/network.sh\" && download_with_retries \"http://example.com/file\" \"$outfile\""
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "network.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/network.sh"
		source "$LIB_DIR/network.sh"
		source "$LIB_DIR/network.sh"
		declare -f port_available >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "network.sh: sets _LGTM_CI_NETWORK_LOADED guard" {
	run bash -c 'source "$LIB_DIR/network.sh" && echo "${_LGTM_CI_NETWORK_LOADED}"'
	assert_success
	assert_output "1"
}
