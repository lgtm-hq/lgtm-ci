#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/network/checksum.sh

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
# verify_checksum tests - basic functionality
# =============================================================================

@test "verify_checksum: returns 0 when checksum matches" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test content" >"$test_file"

	# Get the actual checksum
	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" 2>&1"
	assert_success
}

@test "verify_checksum: returns 1 when checksum mismatches" {
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test content" >"$test_file"

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"0000000000000000000000000000000000000000000000000000000000000000\" 2>&1"
	assert_failure
	assert_output --partial "Checksum mismatch"
}

@test "verify_checksum: returns 1 for missing file" {
	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"${BATS_TEST_TMPDIR}/nonexistent.txt\" \"abc123\" 2>&1"
	assert_failure
	assert_output --partial "File not found"
}

# =============================================================================
# verify_checksum tests - algorithm selection
# =============================================================================

@test "verify_checksum: uses sha256 by default" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test content" >"$test_file"

	# Get sha256 checksum
	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" 2>&1"
	assert_success
}

@test "verify_checksum: supports sha512 algorithm" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test content" >"$test_file"

	# Get sha512 checksum
	local expected
	if command -v sha512sum &>/dev/null; then
		expected=$(sha512sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 512 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" sha512 2>&1"
	assert_success
}

# =============================================================================
# verify_checksum tests - skip-if-unavailable flag
# =============================================================================

@test "verify_checksum: --skip-if-unavailable returns success when no tool available" {
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test" >"$test_file"

	# Use empty PATH to hide sha256sum/shasum binaries from command -v
	run bash -c '
		export PATH=""
		source "$LIB_DIR/network/checksum.sh"
		verify_checksum "'"$test_file"'" "abc123" --skip-if-unavailable 2>&1
	'
	# Assert command returns success when skip-if-unavailable is set and no tool exists
	assert_success
	# Assert output contains skip/warning message indicating checksum was skipped
	assert_output --partial "skip"
}

@test "verify_checksum: warns about unknown options" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test content" >"$test_file"

	# Get the actual checksum for the test to pass
	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" --unknown-flag 2>&1"
	assert_success
	assert_output --partial "Unknown option ignored"
}

# =============================================================================
# verify_checksum tests - verbose output
# =============================================================================

@test "verify_checksum: shows checksum in verbose mode" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test content" >"$test_file"

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "export VERBOSE=1; source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" 2>&1"
	assert_success
	assert_output --partial "Checksum verified"
}

# =============================================================================
# verify_checksum tests - error messages
# =============================================================================

@test "verify_checksum: shows expected and actual on mismatch" {
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "test content" >"$test_file"

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"expected_hash_here\" 2>&1"
	assert_failure
	assert_output --partial "Expected:"
	assert_output --partial "Actual:"
}

@test "verify_checksum: error message includes filename" {
	local test_file="${BATS_TEST_TMPDIR}/specific_file.tar.gz"
	echo "content" >"$test_file"

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"wronghash\" 2>&1"
	assert_failure
	assert_output --partial "specific_file.tar.gz"
}

# =============================================================================
# verify_checksum tests - edge cases
# =============================================================================

@test "verify_checksum: handles files with spaces in name" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/file with spaces.txt"
	echo "content" >"$test_file"

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" 2>&1"
	assert_success
}

@test "verify_checksum: handles empty file" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/empty.txt"
	: >"$test_file"

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" 2>&1"
	assert_success
}

@test "verify_checksum: handles binary files" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/binary.bin"
	printf '\x00\x01\x02\x03\x04\x05' >"$test_file"

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" 2>&1"
	assert_success
}

@test "verify_checksum: handles large files" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/large.bin"
	# Create a 1MB file
	dd if=/dev/zero of="$test_file" bs=1024 count=1024 2>/dev/null

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" 2>&1"
	assert_success
}

# =============================================================================
# verify_checksum tests - argument parsing
# =============================================================================

@test "verify_checksum: accepts positional arguments in order" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "content" >"$test_file"

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	# file, checksum, algorithm
	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum \"$test_file\" \"$expected\" sha256 2>&1"
	assert_success
}

@test "verify_checksum: flags can appear anywhere" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "content" >"$test_file"

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	# flag before positional args
	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && verify_checksum --skip-if-unavailable \"$test_file\" \"$expected\" 2>&1"
	assert_success
}

# =============================================================================
# Function export tests
# =============================================================================

@test "checksum.sh: exports verify_checksum function" {
	run bash -c 'source "$LIB_DIR/network/checksum.sh" && declare -F verify_checksum'
	assert_success
}

@test "checksum.sh: verify_checksum is available in subshell" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "content" >"$test_file"

	local expected
	if command -v sha256sum &>/dev/null; then
		expected=$(sha256sum "$test_file" | awk '{print $1}')
	else
		expected=$(shasum -a 256 "$test_file" | awk '{print $1}')
	fi

	run bash -c "source \"\$LIB_DIR/network/checksum.sh\" && bash -c 'verify_checksum \"$test_file\" \"$expected\"' 2>&1"
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "checksum.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/network/checksum.sh"
		source "$LIB_DIR/network/checksum.sh"
		source "$LIB_DIR/network/checksum.sh"
		declare -F verify_checksum >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "checksum.sh: sets _LGTM_CI_NETWORK_CHECKSUM_LOADED guard" {
	run bash -c 'source "$LIB_DIR/network/checksum.sh" && echo "${_LGTM_CI_NETWORK_CHECKSUM_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Fallback function tests
# =============================================================================

@test "checksum.sh: provides fallback log functions when log.sh unavailable" {
	# Test by creating isolated copy without log.sh
	run bash -c '
		mkdir -p "$BATS_TEST_TMPDIR/isolated/network"
		cp "$LIB_DIR/network/checksum.sh" "$BATS_TEST_TMPDIR/isolated/network/"
		cd "$BATS_TEST_TMPDIR/isolated"
		# Create a test file
		echo "test" > test.txt
		# Source and try to use - should work with fallback functions
		source network/checksum.sh
		declare -F verify_checksum >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Integration tests
# =============================================================================

@test "checksum.sh: sources log.sh automatically when available" {
	run bash -c 'source "$LIB_DIR/network/checksum.sh" && declare -F log_error'
	assert_success
}

@test "checksum.sh: sources fs.sh automatically when available" {
	run bash -c 'source "$LIB_DIR/network/checksum.sh" && declare -F command_exists'
	assert_success
}
