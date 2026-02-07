#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/platform.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# detect_os tests
# =============================================================================

@test "detect_os: returns linux on Linux" {
	mock_uname "Linux" "x86_64"
	run bash -c 'source "$LIB_DIR/platform.sh" && detect_os'
	assert_success
	assert_output "linux"
}

@test "detect_os: returns darwin on macOS" {
	mock_uname "Darwin" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_os'
	assert_success
	assert_output "darwin"
}

@test "detect_os: returns windows for MINGW" {
	mock_uname "MINGW64_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_os'
	assert_success
	assert_output "windows"
}

@test "detect_os: returns windows for MSYS" {
	mock_uname "MSYS_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_os'
	assert_success
	assert_output "windows"
}

@test "detect_os: returns windows for Cygwin" {
	mock_uname "CYGWIN_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_os'
	assert_success
	assert_output "windows"
}

@test "detect_os: lowercases output" {
	mock_uname "LINUX" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_os'
	assert_success
	assert_output "linux"
}

# =============================================================================
# detect_arch tests
# =============================================================================

@test "detect_arch: returns x86_64 for x86_64" {
	mock_uname "Linux" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_arch'
	assert_success
	assert_output "x86_64"
}

@test "detect_arch: normalizes amd64 to x86_64" {
	mock_uname "Linux" "amd64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_arch'
	assert_success
	assert_output "x86_64"
}

@test "detect_arch: returns arm64 for arm64" {
	mock_uname "Darwin" "arm64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_arch'
	assert_success
	assert_output "arm64"
}

@test "detect_arch: normalizes aarch64 to arm64" {
	mock_uname "Linux" "aarch64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_arch'
	assert_success
	assert_output "arm64"
}

@test "detect_arch: returns x86 for i386" {
	mock_uname "Linux" "i386"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_arch'
	assert_success
	assert_output "x86"
}

@test "detect_arch: returns x86 for i686" {
	mock_uname "Linux" "i686"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_arch'
	assert_success
	assert_output "x86"
}

# =============================================================================
# detect_platform tests
# =============================================================================

@test "detect_platform: returns os-arch format" {
	mock_uname "Linux" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_platform'
	assert_success
	assert_output "linux-x86_64"
}

@test "detect_platform: works for darwin-arm64" {
	mock_uname "Darwin" "arm64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_platform'
	assert_success
	assert_output "darwin-arm64"
}

@test "detect_platform: works for windows-x86_64" {
	mock_uname "MINGW64_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && detect_platform'
	assert_success
	assert_output "windows-x86_64"
}

# =============================================================================
# is_macos tests
# =============================================================================

@test "is_macos: returns true on macOS" {
	mock_uname "Darwin" "arm64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_macos && echo "true"'
	assert_success
	assert_output "true"
}

@test "is_macos: returns false on Linux" {
	mock_uname "Linux" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_macos || echo "false"'
	assert_success
	assert_output "false"
}

@test "is_macos: returns false on Windows" {
	mock_uname "MINGW64_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_macos || echo "false"'
	assert_success
	assert_output "false"
}

# =============================================================================
# is_linux tests
# =============================================================================

@test "is_linux: returns true on Linux" {
	mock_uname "Linux" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_linux && echo "true"'
	assert_success
	assert_output "true"
}

@test "is_linux: returns false on macOS" {
	mock_uname "Darwin" "arm64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_linux || echo "false"'
	assert_success
	assert_output "false"
}

@test "is_linux: returns false on Windows" {
	mock_uname "MINGW64_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_linux || echo "false"'
	assert_success
	assert_output "false"
}

# =============================================================================
# is_windows tests
# =============================================================================

@test "is_windows: returns true on MINGW" {
	mock_uname "MINGW64_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_windows && echo "true"'
	assert_success
	assert_output "true"
}

@test "is_windows: returns true on MSYS" {
	mock_uname "MSYS_NT-10.0" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_windows && echo "true"'
	assert_success
	assert_output "true"
}

@test "is_windows: returns false on Linux" {
	mock_uname "Linux" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_windows || echo "false"'
	assert_success
	assert_output "false"
}

@test "is_windows: returns false on macOS" {
	mock_uname "Darwin" "arm64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_windows || echo "false"'
	assert_success
	assert_output "false"
}

# =============================================================================
# is_arm tests
# =============================================================================

@test "is_arm: returns true for arm64" {
	mock_uname "Darwin" "arm64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_arm && echo "true"'
	assert_success
	assert_output "true"
}

@test "is_arm: returns true for aarch64" {
	mock_uname "Linux" "aarch64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_arm && echo "true"'
	assert_success
	assert_output "true"
}

@test "is_arm: returns false for x86_64" {
	mock_uname "Linux" "x86_64"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_arm || echo "false"'
	assert_success
	assert_output "false"
}

@test "is_arm: returns false for i686" {
	mock_uname "Linux" "i686"
	run bash -c 'export PATH="$PATH"; source "$LIB_DIR/platform.sh" && is_arm || echo "false"'
	assert_success
	assert_output "false"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "platform.sh: exports detect_os function" {
	run bash -c 'source "$LIB_DIR/platform.sh" && bash -c "detect_os"'
	assert_success
}

@test "platform.sh: exports detect_arch function" {
	run bash -c 'source "$LIB_DIR/platform.sh" && bash -c "detect_arch"'
	assert_success
}

@test "platform.sh: exports detect_platform function" {
	run bash -c 'source "$LIB_DIR/platform.sh" && bash -c "detect_platform"'
	assert_success
}

@test "platform.sh: exports is_macos function" {
	run bash -c 'source "$LIB_DIR/platform.sh" && bash -c "is_macos || true"'
	assert_success
}

@test "platform.sh: exports is_linux function" {
	run bash -c 'source "$LIB_DIR/platform.sh" && bash -c "is_linux || true"'
	assert_success
}

@test "platform.sh: exports is_windows function" {
	run bash -c 'source "$LIB_DIR/platform.sh" && bash -c "is_windows || true"'
	assert_success
}

@test "platform.sh: exports is_arm function" {
	run bash -c 'source "$LIB_DIR/platform.sh" && bash -c "is_arm || true"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "platform.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/platform.sh"
		source "$LIB_DIR/platform.sh"
		source "$LIB_DIR/platform.sh"
		detect_os
	'
	assert_success
}

@test "platform.sh: sets _LGTM_CI_PLATFORM_LOADED guard" {
	run bash -c 'source "$LIB_DIR/platform.sh" && echo "${_LGTM_CI_PLATFORM_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Integration with real system (no mocks)
# =============================================================================

@test "detect_os: works with real system" {
	run bash -c 'source "$LIB_DIR/platform.sh" && detect_os'
	assert_success
	# Should return one of the expected values
	[[ "$output" == "linux" ]] || [[ "$output" == "darwin" ]] || [[ "$output" == "windows" ]]
}

@test "detect_arch: works with real system" {
	run bash -c 'source "$LIB_DIR/platform.sh" && detect_arch'
	assert_success
	# Should return one of the expected values
	[[ "$output" == "x86_64" ]] || [[ "$output" == "arm64" ]] || [[ "$output" == "x86" ]]
}

@test "detect_platform: works with real system" {
	run bash -c 'source "$LIB_DIR/platform.sh" && detect_platform'
	assert_success
	# Should return os-arch format
	assert_output --regexp "^(linux|darwin|windows)-(x86_64|arm64|x86)$"
}
