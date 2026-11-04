#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/extract-version-from-commit.sh

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
# Helper
# =============================================================================

run_extract() {
	local commit_msg="$1"
	run env \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		COMMIT_MESSAGE="$commit_msg" \
		bash -c "'$PROJECT_ROOT/scripts/ci/release/extract-version-from-commit.sh' 2>&1"
}

run_extract_from_git() {
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		unset COMMIT_MESSAGE
		'$PROJECT_ROOT/scripts/ci/release/extract-version-from-commit.sh' 2>&1
	"
}

# =============================================================================
# Tests: env var override
# =============================================================================

@test "extract-version: extracts 1.2.3 from commit message" {
	run_extract "chore(release): version 1.2.3"
	assert_success
	assert_line --partial "version=1.2.3"
	assert_line --partial "found=true"
}

@test "extract-version: extracts 0.1.0 from commit message" {
	run_extract "chore(release): version 0.1.0"
	assert_success
	assert_line --partial "version=0.1.0"
	assert_line --partial "found=true"
}

@test "extract-version: extracts 10.20.30 from commit message" {
	run_extract "chore(release): version 10.20.30"
	assert_success
	assert_line --partial "version=10.20.30"
	assert_line --partial "found=true"
}

@test "extract-version: fails on feat commit" {
	run_extract "feat: add something"
	assert_failure
	assert_line --partial "found=false"
}

@test "extract-version: fails on chore(release) without version number" {
	run_extract "chore(release): bump"
	assert_failure
	assert_line --partial "found=false"
}

@test "extract-version: fails on non-semver version" {
	run_extract "chore(release): version abc"
	assert_failure
	assert_line --partial "found=false"
}

# =============================================================================
# Tests: from git
# =============================================================================

@test "extract-version: reads from git when COMMIT_MESSAGE not set" {
	setup_mock_git_repo
	add_commit "chore(release): version 3.0.0"

	run_extract_from_git
	assert_success
	assert_line --partial "version=3.0.0"
	assert_line --partial "found=true"
}

@test "extract-version: accepts prepare v with an optional numeric PR suffix" {
	local subject
	for subject in \
		"chore(release): prepare v0.83.11" \
		"chore(release): prepare v0.83.11 (#1321)"; do
		run_extract "$subject"
		assert_success
		assert_line "version=0.83.11"
		assert_line "found=true"
		assert_github_output "version" "0.83.11"
		assert_github_output "found" "true"
	done
}

@test "extract-version: rejects malformed prepare versions and suffixes" {
	local subject
	for subject in \
		"chore(release): prepare" \
		"chore(release): prepare v" \
		"chore(release): prepare 0.83.11" \
		"chore(release): prepare V0.83.11" \
		"chore(release): prepare v0.83" \
		"chore(release): prepare v0.83.11.2" \
		"chore(release): prepare v0.83.11-rc.1" \
		"chore(release): prepare v0.83.11+build.1" \
		"chore(release): prepare v0.83.11extra" \
		"chore(release): prepare v0.83.11 " \
		"chore(release): prepare v0.83.11 (#)" \
		"chore(release): prepare v0.83.11 (#abc)" \
		"chore(release): prepare v0.83.11 (#1321" \
		"chore(release): prepare v0.83.11(#1321)" \
		"chore(release): prepare v0.83.11  (#1321)" \
		"chore(release): prepare v0.83.11 (#1321) extra" \
		"chore(release): prepare v0.83.11 (#1321) (#1322)" \
		"chore(release): prepare v0.83.11 (PR #1321)" \
		"chore(release): prepare v0.83.11 (#1321 extra)"; do
		: >"$GITHUB_OUTPUT"
		run_extract "$subject"
		assert_failure 1
		assert_line "version="
		assert_line "found=false"
		assert_equal $'version=\nfound=false' "$(cat "$GITHUB_OUTPUT")"
	done
}

@test "extract-version: prepare versions retain semver validation" {
	local version
	for version in 00.83.11 0.083.11 0.83.011; do
		: >"$GITHUB_OUTPUT"
		run_extract "chore(release): prepare v${version} (#1321)"
		assert_failure 1
		assert_equal $'version=\nfound=false' "$(cat "$GITHUB_OUTPUT")"
	done
}

@test "extract-version: rejects unrelated subjects containing a prepare version" {
	local subject
	for subject in \
		"feat: prepare v0.83.11" \
		"chore: prepare v0.83.11" \
		"chore(other): prepare v0.83.11" \
		"prefix chore(release): prepare v0.83.11" \
		"chore(release): notes prepare v0.83.11"; do
		run_extract "$subject"
		assert_failure 1
		assert_line "found=false"
	done
}

@test "extract-version: treats command substitutions and shell syntax as subject text" {
	local subject marker="$BATS_TEST_TMPDIR/subject-executed"
	# shellcheck disable=SC2016 # Literal command substitution is the subject under test.
	printf -v subject 'chore(release): prepare v0.83.11 $(touch "%s")' "$marker"
	run_extract "$subject"
	assert_failure 1
	assert_line "found=false"
	assert_file_not_exists "$marker"
	printf -v subject 'chore(release): prepare v0.83.11; touch "%s"' "$marker"
	run_extract "$subject"
	assert_failure 1
	assert_line "found=false"
	assert_file_not_exists "$marker"
}
