#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for CI action scripts

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# Library loading integration tests
# =============================================================================

@test "integration: all core libraries can be sourced together" {
	run bash -c '
		set -e
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/platform.sh"
		source "$LIB_DIR/fs.sh"
		source "$LIB_DIR/git.sh"
		echo "all loaded"
	'
	assert_success
	assert_output "all loaded"
}

@test "integration: libraries work correctly when sourced in any order" {
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/git.sh"
		source "$LIB_DIR/fs.sh"
		source "$LIB_DIR/platform.sh"
		source "$LIB_DIR/log.sh"

		cd "$PROJECT_ROOT"
		is_git_repo

		tmp="${BATS_TEST_TMPDIR}/order-test"
		ensure_directory "$tmp"
		[[ -d "$tmp" ]]

		os=$(detect_os)
		arch=$(detect_arch)
		[[ "$os" =~ ^(linux|darwin|windows)$ ]]
		[[ "$arch" =~ ^(x86_64|arm64|x86)$ ]]

		log_info "test" 2>&1
	'
	assert_success
	assert_output --partial "[INFO]"
}

@test "integration: github output libraries integrate correctly" {
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/github/output.sh"
		set_github_output "test" "value"
		log_info "done" 2>&1
	'
	assert_success
	assert_output --partial "[INFO]"
	assert_github_output "test" "value"
}

@test "integration: release version library works standalone" {
	run bash -c '
		source "$LIB_DIR/release/version.sh"
		validate_semver "1.0.0" && bump_version "1.0.0" "minor"
	'
	assert_success
	assert_output "1.1.0"
}

@test "integration: network checksum integrates with fs utilities" {
	if ! bash4_available; then
		skip "requires bash 4+ (log_verbose uses lowercase syntax)"
	fi
	local test_file="${BATS_TEST_TMPDIR}/test.txt"
	echo "integration test" >"$test_file"

	# Explicitly choose checksum tool to avoid pipe masking failures
	local checksum
	if command -v sha256sum >/dev/null 2>&1; then
		checksum=$(sha256sum "$test_file" | awk '{print $1}')
	elif command -v shasum >/dev/null 2>&1; then
		checksum=$(shasum -a 256 "$test_file" | awk '{print $1}')
	else
		skip "no sha256sum or shasum available"
	fi

	run bash -c "
		source \"\$LIB_DIR/fs.sh\"
		source \"\$LIB_DIR/network/checksum.sh\"
		require_file \"$test_file\"
		verify_checksum \"$test_file\" \"$checksum\" 2>&1
	"
	assert_success
}

# =============================================================================
# Environment simulation tests
# =============================================================================

@test "integration: GitHub Actions environment is properly simulated" {
	run bash -c '
		set -euo pipefail
		[[ "$GITHUB_ACTIONS" == "true" ]]
		[[ -f "$GITHUB_OUTPUT" ]]
		[[ -f "$GITHUB_ENV" ]]
		[[ -f "$GITHUB_PATH" ]]
		[[ -f "$GITHUB_STEP_SUMMARY" ]]
		[[ -n "$GITHUB_REPOSITORY" ]]
		[[ -n "$RUNNER_OS" ]]
		echo "env ok"
	'
	assert_success
	assert_output "env ok"
}

@test "integration: GitHub outputs persist across function calls" {
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/github/output.sh"
		set_github_output "first" "1"
		set_github_output "second" "2"
		set_github_output "third" "3"
	'
	assert_success

	# Verify all outputs are set
	assert_github_output "first" "1"
	assert_github_output "second" "2"
	assert_github_output "third" "3"
}

# =============================================================================
# Error handling integration tests
# =============================================================================

@test "integration: die function works with log library" {
	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/fs.sh"
		die "test error" 2>&1
	'
	assert_failure
	assert_output --partial "[ERROR]"
	assert_output --partial "test error"
}

@test "integration: require_command uses log functions" {
	run bash -c '
		source "$LIB_DIR/fs.sh"
		require_command "nonexistent_command_xyz" 2>&1
	'
	assert_failure
	assert_exit_code 1
	assert_output --partial "[ERROR]"
	assert_output --partial "Required command not found: nonexistent_command_xyz"
}

# =============================================================================
# Cross-platform detection tests
# =============================================================================

@test "integration: platform detection provides consistent results" {
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/platform.sh"
		os=$(detect_os)
		arch=$(detect_arch)
		platform=$(detect_platform)
		[[ "$os" =~ ^(linux|darwin|windows)$ ]]
		[[ "$arch" =~ ^(x86_64|arm64|x86)$ ]]
		[[ "$platform" == "$os-$arch" ]] && echo "consistent"
	'
	assert_success
	assert_output "consistent"
}

@test "integration: platform checks are mutually exclusive" {
	run bash -c '
		source "$LIB_DIR/platform.sh"
		count=0
		is_macos && count=$((count + 1))
		is_linux && count=$((count + 1))
		is_windows && count=$((count + 1))
		[[ $count -eq 1 ]] && echo "exclusive"
	'
	assert_success
	assert_output "exclusive"
}

# =============================================================================
# Git integration tests
# =============================================================================

@test "integration: git functions work in real repository" {
	cd "$PROJECT_ROOT"
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/git.sh"
		root=$(get_git_root)
		[[ "$root" == "$PROJECT_ROOT" ]]
		is_git_repo
		sha=$(get_commit_sha)
		[[ "$sha" =~ ^[0-9a-f]{40}$ ]] && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "integration: git branch detection works" {
	cd "$PROJECT_ROOT"
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/git.sh"
		expected=$(git rev-parse --abbrev-ref HEAD)
		branch=$(get_current_branch)
		[[ "$branch" == "$expected" ]] && echo "matches"
	'
	assert_success
	assert_output "matches"
}

@test "integration: git sha functions return valid format" {
	cd "$PROJECT_ROOT"
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/git.sh"
		full=$(get_commit_sha)
		short=$(get_short_sha)
		[[ "$full" =~ ^[0-9a-f]{40}$ ]]
		[[ "$short" =~ ^[0-9a-f]{7}$ ]]
		[[ "$full" == "$short"* ]] && echo "valid"
	'
	assert_success
	assert_output "valid"
}

# =============================================================================
# Temp directory integration tests
# =============================================================================

@test "integration: create_temp_dir cleanup works in nested calls" {
	# Note: When create_temp_dir is called inside command substitution, the EXIT trap
	# runs when the subshell exits, which cleans up the directories. This test
	# verifies the path format rather than directory existence.
	run bash -c '
		set -euo pipefail
		source "$LIB_DIR/fs.sh"
		outer=$(create_temp_dir)
		inner=$(create_temp_dir)
		[[ "$outer" != "$inner" ]]
		[[ "$outer" == *lgtm-ci* ]] && [[ "$inner" == *lgtm-ci* ]] && echo "both created"
	'
	assert_success
	assert_output "both created"
}

@test "integration: temp directories are cleaned up on exit" {
	local captured_dir
	captured_dir=$(bash -c '
		source "$LIB_DIR/fs.sh"
		tmpdir=$(create_temp_dir)
		echo "$tmpdir"
	')

	# Verify we captured a valid directory path
	[[ -n "$captured_dir" ]] || fail "create_temp_dir returned empty string"

	# After subshell exits, directory should be gone
	[[ ! -d "$captured_dir" ]]
}

# =============================================================================
# Version comparison integration tests
# =============================================================================

@test "integration: version functions work together" {
	run bash -c '
		source "$LIB_DIR/release/version.sh"
		v1="1.0.0"
		v2=$(bump_version "$v1" "minor")
		compare_versions "$v2" "$v1"
		result=$?
		[[ $result -eq 1 ]] && echo "v2 > v1"
	'
	assert_success
	assert_output "v2 > v1"
}

@test "integration: version validation and bumping chain correctly" {
	run bash -c '
		source "$LIB_DIR/release/version.sh"
		v="1.0.0"
		validate_semver "$v" || exit 1
		v=$(bump_version "$v" "patch")
		validate_semver "$v" || exit 1
		v=$(bump_version "$v" "minor")
		validate_semver "$v" || exit 1
		v=$(bump_version "$v" "major")
		validate_semver "$v" || exit 1
		echo "$v"
	'
	assert_success
	assert_output "2.0.0"
}
