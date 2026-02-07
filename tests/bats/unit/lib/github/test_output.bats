#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/github/output.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# set_github_output tests
# =============================================================================

@test "set_github_output: writes key=value to GITHUB_OUTPUT" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output "version" "1.0.0"'
	assert_success

	run get_github_output "version"
	assert_success
	assert_output "1.0.0"
}

@test "set_github_output: handles values with special characters" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output "message" "Hello, World! @#\$%"'
	assert_success

	run get_github_output "message"
	assert_success
	assert_output 'Hello, World! @#$%'
}

@test "set_github_output: handles values with spaces" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output "name" "John Doe"'
	assert_success

	run get_github_output "name"
	assert_success
	assert_output "John Doe"
}

@test "set_github_output: handles empty value" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output "empty" ""'
	assert_success

	# get_github_output returns exit code 1 when value is empty, but file contains the key
	run grep "^empty=" "$GITHUB_OUTPUT"
	assert_success
	assert_output "empty="
}

@test "set_github_output: does nothing when GITHUB_OUTPUT unset" {
	unset GITHUB_OUTPUT
	run bash -c 'unset GITHUB_OUTPUT; source "$LIB_DIR/github/output.sh" && set_github_output "key" "value"'
	assert_success
}

@test "set_github_output: multiple outputs append to file" {
	run bash -c '
		source "$LIB_DIR/github/output.sh"
		set_github_output "first" "1"
		set_github_output "second" "2"
		set_github_output "third" "3"
	'
	assert_success

	run get_github_output "first"
	assert_output "1"

	run get_github_output "second"
	assert_output "2"

	run get_github_output "third"
	assert_output "3"
}

# =============================================================================
# set_github_output_multiline tests
# =============================================================================

@test "set_github_output_multiline: writes multiline value correctly" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output_multiline "changelog" "line1
line2
line3"'
	assert_success

	run get_github_output "changelog"
	assert_success
	assert_line "line1"
	assert_line "line2"
	assert_line "line3"
}

@test "set_github_output_multiline: handles values with special characters" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output_multiline "json" "{
  \"key\": \"value\",
  \"number\": 123
}"'
	assert_success

	run get_github_output "json"
	assert_success
	assert_line --partial '"key"'
}

@test "set_github_output_multiline: uses unique delimiter" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output_multiline "data" "test"'
	assert_success

	# Check that the file contains the delimiter pattern
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "LGTM_CI_EOF_"
}

@test "set_github_output_multiline: does nothing when GITHUB_OUTPUT unset" {
	unset GITHUB_OUTPUT
	run bash -c 'unset GITHUB_OUTPUT; source "$LIB_DIR/github/output.sh" && set_github_output_multiline "key" "value"'
	assert_success
}

# =============================================================================
# set_github_env tests
# =============================================================================

@test "set_github_env: writes key=value to GITHUB_ENV" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_env "MY_VAR" "my_value"'
	assert_success

	run get_github_env "MY_VAR"
	assert_success
	assert_output "my_value"
}

@test "set_github_env: handles values with special characters" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_env "PATH_VAR" "/usr/bin:/opt/bin"'
	assert_success

	run get_github_env "PATH_VAR"
	assert_success
	assert_output "/usr/bin:/opt/bin"
}

@test "set_github_env: does nothing when GITHUB_ENV unset" {
	unset GITHUB_ENV
	run bash -c 'unset GITHUB_ENV; source "$LIB_DIR/github/output.sh" && set_github_env "key" "value"'
	assert_success
}

@test "set_github_env: multiple envs append to file" {
	run bash -c '
		source "$LIB_DIR/github/output.sh"
		set_github_env "VAR1" "value1"
		set_github_env "VAR2" "value2"
	'
	assert_success

	run get_github_env "VAR1"
	assert_output "value1"

	run get_github_env "VAR2"
	assert_output "value2"
}

# =============================================================================
# add_github_path tests
# =============================================================================

@test "add_github_path: adds directory to GITHUB_PATH" {
	local test_dir="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$test_dir"

	run bash -c "source \"\$LIB_DIR/github/output.sh\" && add_github_path \"$test_dir\""
	assert_success

	run cat "$GITHUB_PATH"
	assert_output --partial "$test_dir"
}

@test "add_github_path: does nothing for nonexistent directory" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && add_github_path "/nonexistent/path"'
	assert_success

	run cat "$GITHUB_PATH"
	refute_output --partial "/nonexistent/path"
}

@test "add_github_path: does nothing when GITHUB_PATH unset" {
	unset GITHUB_PATH
	run bash -c 'unset GITHUB_PATH; source "$LIB_DIR/github/output.sh" && add_github_path "/some/path"'
	assert_success
}

@test "add_github_path: multiple paths append to file" {
	local dir1="${BATS_TEST_TMPDIR}/bin1"
	local dir2="${BATS_TEST_TMPDIR}/bin2"
	mkdir -p "$dir1" "$dir2"

	run bash -c "
		source \"\$LIB_DIR/github/output.sh\"
		add_github_path \"$dir1\"
		add_github_path \"$dir2\"
	"
	assert_success

	assert_github_path_contains "$dir1"
	assert_github_path_contains "$dir2"
}

# =============================================================================
# configure_git_ci_user tests
# =============================================================================

@test "configure_git_ci_user: sets git user.name" {
	cd "$BATS_TEST_TMPDIR"
	git init -q

	run bash -c 'source "$LIB_DIR/github/output.sh" && configure_git_ci_user && git config user.name'
	assert_success
	assert_output "github-actions[bot]"
}

@test "configure_git_ci_user: sets git user.email" {
	cd "$BATS_TEST_TMPDIR"
	git init -q

	run bash -c 'source "$LIB_DIR/github/output.sh" && configure_git_ci_user && git config user.email'
	assert_success
	assert_output "github-actions[bot]@users.noreply.github.com"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "output.sh: exports set_github_output function" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && bash -c "set_github_output test value"'
	assert_success
}

@test "output.sh: exports set_github_output_multiline function" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && bash -c "set_github_output_multiline test value"'
	assert_success
}

@test "output.sh: exports set_github_env function" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && bash -c "set_github_env test value"'
	assert_success
}

@test "output.sh: exports add_github_path function" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && bash -c "add_github_path /tmp || true"'
	assert_success
}

@test "output.sh: exports configure_git_ci_user function" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && bash -c "declare -F configure_git_ci_user"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "output.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/github/output.sh"
		source "$LIB_DIR/github/output.sh"
		source "$LIB_DIR/github/output.sh"
		set_github_output "test" "value"
	'
	assert_success
}

@test "output.sh: sets _LGTM_CI_GITHUB_OUTPUT_LOADED guard" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && echo "${_LGTM_CI_GITHUB_OUTPUT_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Integration with GitHub Actions environment
# =============================================================================

@test "set_github_output: assertion helper works" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output "result" "success"'
	assert_success
	assert_github_output "result" "success"
}

@test "set_github_output_multiline: assertion helper works for multiline" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_output_multiline "log" "line1
line2"'
	assert_success
	assert_github_output_contains "log" "line1"
	assert_github_output_contains "log" "line2"
}

@test "set_github_env: assertion helper works" {
	run bash -c 'source "$LIB_DIR/github/output.sh" && set_github_env "BUILD_TYPE" "release"'
	assert_success
	assert_github_env "BUILD_TYPE" "release"
}
