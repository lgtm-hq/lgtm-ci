#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/git.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR

	# Create a real git repo for integration tests
	setup_mock_git_repo
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# get_git_root tests
# =============================================================================

@test "get_git_root: returns repo root directory" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && get_git_root'
	assert_success
	# Use partial match because macOS resolves /var to /private/var
	assert_output --partial "bats-test"
	assert_output --partial "/repo"
}

@test "get_git_root: works from subdirectory" {
	mkdir -p "${MOCK_GIT_REPO}/sub/dir"
	cd "${MOCK_GIT_REPO}/sub/dir"
	run bash -c 'source "$LIB_DIR/git.sh" && get_git_root'
	assert_success
	# Use partial match because macOS resolves /var to /private/var
	assert_output --partial "bats-test"
	assert_output --partial "/repo"
}

@test "get_git_root: returns empty outside git repo" {
	cd "$BATS_TEST_TMPDIR"
	# Create a non-git directory
	mkdir -p "${BATS_TEST_TMPDIR}/not_a_repo"
	cd "${BATS_TEST_TMPDIR}/not_a_repo"
	run bash -c 'source "$LIB_DIR/git.sh" && get_git_root'
	assert_failure
	refute_output
}

# =============================================================================
# get_current_branch tests
# =============================================================================

@test "get_current_branch: returns current branch name" {
	cd "$MOCK_GIT_REPO"
	local expected_branch
	expected_branch=$(git rev-parse --abbrev-ref HEAD)
	run bash -c 'source "$LIB_DIR/git.sh" && get_current_branch'
	assert_success
	assert_output "$expected_branch"
}

@test "get_current_branch: returns feature branch name" {
	cd "$MOCK_GIT_REPO"
	git checkout -q -b feature/test-branch
	run bash -c 'source "$LIB_DIR/git.sh" && get_current_branch'
	assert_success
	assert_output "feature/test-branch"
}

@test "get_current_branch: works with branch names containing slashes" {
	cd "$MOCK_GIT_REPO"
	git checkout -q -b "feature/deep/nested/branch"
	run bash -c 'source "$LIB_DIR/git.sh" && get_current_branch'
	assert_success
	assert_output "feature/deep/nested/branch"
}

# =============================================================================
# get_commit_sha tests
# =============================================================================

@test "get_commit_sha: returns 40-character SHA" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && get_commit_sha'
	assert_success
	assert_output --regexp "^[0-9a-f]{40}$"
}

@test "get_commit_sha: returns empty outside git repo" {
	mkdir -p "${BATS_TEST_TMPDIR}/not_a_repo"
	cd "${BATS_TEST_TMPDIR}/not_a_repo"
	run bash -c 'source "$LIB_DIR/git.sh" && get_commit_sha'
	assert_failure
	refute_output
}

# =============================================================================
# get_short_sha tests
# =============================================================================

@test "get_short_sha: returns exactly 7 characters" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && get_short_sha'
	assert_success
	assert_output --regexp "^[0-9a-f]{7}$"
}

@test "get_short_sha: matches beginning of full SHA" {
	cd "$MOCK_GIT_REPO"
	local full_sha
	full_sha=$(git rev-parse HEAD)
	run bash -c 'source "$LIB_DIR/git.sh" && get_short_sha'
	assert_success
	[[ "$full_sha" == "$output"* ]]
}

# =============================================================================
# is_git_repo tests
# =============================================================================

@test "is_git_repo: returns true inside git repo" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_repo && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_git_repo: returns true from subdirectory" {
	mkdir -p "${MOCK_GIT_REPO}/deep/nested"
	cd "${MOCK_GIT_REPO}/deep/nested"
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_repo && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_git_repo: returns false outside git repo" {
	mkdir -p "${BATS_TEST_TMPDIR}/not_a_repo"
	cd "${BATS_TEST_TMPDIR}/not_a_repo"
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_repo || echo "no"'
	assert_success
	assert_output "no"
}

# =============================================================================
# is_git_clean tests
# =============================================================================

@test "is_git_clean: returns true for clean repo" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_clean && echo "clean"'
	assert_success
	assert_output "clean"
}

@test "is_git_clean: returns false with uncommitted changes" {
	cd "$MOCK_GIT_REPO"
	echo "modified" >>README.md
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_clean || echo "dirty"'
	assert_success
	assert_output "dirty"
}

@test "is_git_clean: returns false with untracked files" {
	cd "$MOCK_GIT_REPO"
	echo "new file" >untracked.txt
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_clean || echo "dirty"'
	assert_success
	assert_output "dirty"
}

@test "is_git_clean: returns false with staged changes" {
	cd "$MOCK_GIT_REPO"
	echo "new content" >new_file.txt
	git add new_file.txt
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_clean || echo "dirty"'
	assert_success
	assert_output "dirty"
}

@test "is_git_clean: returns false outside git repo" {
	mkdir -p "${BATS_TEST_TMPDIR}/not_a_repo"
	cd "${BATS_TEST_TMPDIR}/not_a_repo"
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_clean || echo "not clean"'
	assert_success
	assert_output "not clean"
}

# =============================================================================
# get_git_remote_url tests
# =============================================================================

@test "get_git_remote_url: returns origin URL when set" {
	cd "$MOCK_GIT_REPO"
	git remote add origin "git@github.com:test/repo.git"
	run bash -c 'source "$LIB_DIR/git.sh" && get_git_remote_url'
	assert_success
	assert_output "git@github.com:test/repo.git"
}

@test "get_git_remote_url: returns empty when no origin" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && get_git_remote_url'
	assert_failure
	refute_output
}

@test "get_git_remote_url: handles HTTPS URLs" {
	cd "$MOCK_GIT_REPO"
	git remote add origin "https://github.com/test/repo.git"
	run bash -c 'source "$LIB_DIR/git.sh" && get_git_remote_url'
	assert_success
	assert_output "https://github.com/test/repo.git"
}

# =============================================================================
# get_latest_tag tests
# =============================================================================

@test "get_latest_tag: returns latest tag matching pattern" {
	cd "$MOCK_GIT_REPO"
	git tag v1.0.0
	echo "change" >>README.md
	git add README.md
	git commit -q -m "Change"
	git tag v1.1.0
	run bash -c 'source "$LIB_DIR/git.sh" && get_latest_tag "v*"'
	assert_success
	assert_output "v1.1.0"
}

@test "get_latest_tag: uses v* pattern by default" {
	cd "$MOCK_GIT_REPO"
	git tag v2.0.0
	run bash -c 'source "$LIB_DIR/git.sh" && get_latest_tag'
	assert_success
	assert_output "v2.0.0"
}

@test "get_latest_tag: returns empty when no tags exist" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && get_latest_tag'
	assert_failure
	refute_output
}

@test "get_latest_tag: filters by pattern" {
	cd "$MOCK_GIT_REPO"
	git tag v1.0.0
	git tag beta-1.0.0
	run bash -c 'source "$LIB_DIR/git.sh" && get_latest_tag "beta-*"'
	assert_success
	assert_output "beta-1.0.0"
}

# =============================================================================
# get_tags tests
# =============================================================================

@test "get_tags: returns tags sorted by version" {
	cd "$MOCK_GIT_REPO"
	git tag v1.0.0
	git tag v1.1.0
	git tag v2.0.0
	git tag v1.10.0
	run bash -c 'source "$LIB_DIR/git.sh" && get_tags "v*"'
	assert_success
	# Should be sorted with highest version first
	assert_line --index 0 "v2.0.0"
}

@test "get_tags: returns multiple tags" {
	cd "$MOCK_GIT_REPO"
	git tag v1.0.0
	git tag v1.1.0
	run bash -c 'source "$LIB_DIR/git.sh" && get_tags'
	assert_success
	local line_count
	line_count=$(echo "$output" | wc -l)
	[[ "$line_count" -ge 2 ]]
}

@test "get_tags: uses v* pattern by default" {
	cd "$MOCK_GIT_REPO"
	git tag v1.0.0
	git tag release-1.0.0
	run bash -c 'source "$LIB_DIR/git.sh" && get_tags'
	assert_success
	assert_output "v1.0.0"
}

@test "get_tags: returns empty when no matching tags" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && get_tags "nonexistent-*"'
	assert_success
	refute_output
}

# =============================================================================
# tag_exists tests
# =============================================================================

@test "tag_exists: returns true for existing tag" {
	cd "$MOCK_GIT_REPO"
	git tag v1.0.0
	run bash -c 'source "$LIB_DIR/git.sh" && tag_exists "v1.0.0" && echo "exists"'
	assert_success
	assert_output "exists"
}

@test "tag_exists: returns false for nonexistent tag" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && tag_exists "v99.99.99" || echo "not found"'
	assert_success
	assert_output "not found"
}

@test "tag_exists: returns false for empty tag name" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && tag_exists "" || echo "not found"'
	assert_success
	assert_output "not found"
}

@test "tag_exists: handles tag names with special characters" {
	cd "$MOCK_GIT_REPO"
	git tag "v1.0.0-alpha.1"
	run bash -c 'source "$LIB_DIR/git.sh" && tag_exists "v1.0.0-alpha.1" && echo "exists"'
	assert_success
	assert_output "exists"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "git.sh: exports get_git_root function" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && bash -c "get_git_root"'
	assert_success
}

@test "git.sh: exports get_current_branch function" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && bash -c "get_current_branch"'
	assert_success
}

@test "git.sh: exports is_git_repo function" {
	cd "$MOCK_GIT_REPO"
	run bash -c 'source "$LIB_DIR/git.sh" && bash -c "is_git_repo && echo yes"'
	assert_success
	assert_output "yes"
}

@test "git.sh: exports tag_exists function" {
	cd "$MOCK_GIT_REPO"
	git tag test-tag
	run bash -c 'source "$LIB_DIR/git.sh" && bash -c "tag_exists test-tag && echo yes"'
	assert_success
	assert_output "yes"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "git.sh: can be sourced multiple times without error" {
	cd "$MOCK_GIT_REPO"
	run bash -c '
		source "$LIB_DIR/git.sh"
		source "$LIB_DIR/git.sh"
		source "$LIB_DIR/git.sh"
		is_git_repo && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "git.sh: sets _LGTM_CI_GIT_LOADED guard" {
	run bash -c 'source "$LIB_DIR/git.sh" && echo "${_LGTM_CI_GIT_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Edge cases
# =============================================================================

@test "get_current_branch: handles detached HEAD" {
	cd "$MOCK_GIT_REPO"
	local sha
	sha=$(git rev-parse HEAD)
	git checkout -q "$sha"
	run bash -c 'source "$LIB_DIR/git.sh" && get_current_branch'
	assert_success
	assert_output "HEAD"
}

@test "is_git_clean: returns clean after commit" {
	cd "$MOCK_GIT_REPO"
	echo "new content" >new_file.txt
	git add new_file.txt
	git commit -q -m "Add new file"
	run bash -c 'source "$LIB_DIR/git.sh" && is_git_clean && echo "clean"'
	assert_success
	assert_output "clean"
}
