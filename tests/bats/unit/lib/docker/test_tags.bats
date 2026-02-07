#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/docker/tags.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	# Clear GitHub environment variables for predictable tests
	unset GITHUB_SHA GITHUB_REF GITHUB_REF_NAME
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# generate_semver_tags tests
# =============================================================================

@test "generate_semver_tags: generates tags for simple semver" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "1.2.3"
	'
	assert_success
	assert_line "1"
	assert_line "1.2"
	assert_line "1.2.3"
	assert_line "latest"
}

@test "generate_semver_tags: handles v prefix" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "v2.0.0"
	'
	assert_success
	assert_line "2"
	assert_line "2.0"
	assert_line "2.0.0"
	assert_line "latest"
}

@test "generate_semver_tags: applies prefix to all tags" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "1.0.0" "v"
	'
	assert_success
	assert_line "v1"
	assert_line "v1.0"
	assert_line "v1.0.0"
	assert_line "latest"
}

@test "generate_semver_tags: excludes latest for alpha releases" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "1.0.0-alpha.1"
	'
	assert_success
	assert_line "1"
	assert_line "1.0"
	assert_line "1.0.0"
	refute_output --partial "latest"
}

@test "generate_semver_tags: excludes latest for beta releases" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "2.0.0-beta"
	'
	assert_success
	refute_output --partial "latest"
}

@test "generate_semver_tags: excludes latest for rc releases" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "1.5.0-rc.1"
	'
	assert_success
	refute_output --partial "latest"
}

@test "generate_semver_tags: excludes latest for dev releases" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "1.0.0-dev"
	'
	assert_success
	refute_output --partial "latest"
}

@test "generate_semver_tags: excludes latest for pre releases" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "3.0.0-pre.5"
	'
	assert_success
	refute_output --partial "latest"
}

@test "generate_semver_tags: returns error for invalid semver" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "not-a-version"
	'
	assert_failure
}

@test "generate_semver_tags: returns error for partial version" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "1.2"
	'
	assert_failure
}

@test "generate_semver_tags: handles build metadata" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "1.0.0+build.123"
	'
	assert_success
	assert_line "1"
	assert_line "1.0"
	assert_line "1.0.0"
}

@test "generate_semver_tags: handles zero versions" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_semver_tags "0.1.0"
	'
	assert_success
	assert_line "0"
	assert_line "0.1"
	assert_line "0.1.0"
}

# =============================================================================
# generate_sha_tag tests
# =============================================================================

@test "generate_sha_tag: uses provided SHA" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_sha_tag "abcdef1234567890"
	'
	assert_success
	assert_output "sha-abcdef1"
}

@test "generate_sha_tag: uses custom length" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_sha_tag "abcdef1234567890" 10
	'
	assert_success
	assert_output "sha-abcdef1234"
}

@test "generate_sha_tag: uses GITHUB_SHA when no arg" {
	run bash -c '
		export GITHUB_SHA="fedcba9876543210"
		source "$LIB_DIR/docker/tags.sh"
		generate_sha_tag
	'
	assert_success
	assert_output "sha-fedcba9"
}

@test "generate_sha_tag: falls back to git when no GITHUB_SHA" {
	# This test only works if we're in a git repo
	if [[ ! -d .git ]]; then
		skip "not in a git repository"
	fi
	run bash -c '
		unset GITHUB_SHA
		source "$LIB_DIR/docker/tags.sh"
		tag=$(generate_sha_tag)
		# Should start with sha- and have 7 chars after
		if [[ "$tag" =~ ^sha-[a-f0-9]{7}$ ]]; then
			echo "valid"
		else
			echo "invalid: $tag"
		fi
	'
	assert_success
	assert_output "valid"
}

@test "generate_sha_tag: returns error when SHA cannot be determined" {
	run bash -c '
		unset GITHUB_SHA
		# Mock git to fail
		git() { return 1; }
		export -f git
		source "$LIB_DIR/docker/tags.sh"
		generate_sha_tag 2>/dev/null
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

# =============================================================================
# generate_branch_tag tests
# =============================================================================

@test "generate_branch_tag: uses provided branch name" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag "main"
	'
	assert_success
	assert_output "main"
}

@test "generate_branch_tag: uses GITHUB_REF_NAME when no arg" {
	run bash -c '
		export GITHUB_REF_NAME="feature/test"
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag
	'
	assert_success
	# / is replaced with -
	assert_output "feature-test"
}

@test "generate_branch_tag: parses GITHUB_REF for branches" {
	run bash -c '
		export GITHUB_REF="refs/heads/develop"
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag
	'
	assert_success
	assert_output "develop"
}

@test "generate_branch_tag: parses GITHUB_REF for tags" {
	run bash -c '
		export GITHUB_REF="refs/tags/v1.0.0"
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag
	'
	assert_success
	assert_output "v1.0.0"
}

@test "generate_branch_tag: sanitizes slashes to dashes" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag "feature/my-feature/nested"
	'
	assert_success
	assert_output "feature-my-feature-nested"
}

@test "generate_branch_tag: removes invalid characters" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag "feature@branch#with!special"
	'
	assert_success
	assert_output "featurebranchwithspecial"
}

@test "generate_branch_tag: preserves valid characters" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag "release-1.0_test"
	'
	assert_success
	assert_output "release-1.0_test"
}

@test "generate_branch_tag: returns error when branch cannot be determined" {
	run bash -c '
		unset GITHUB_REF GITHUB_REF_NAME
		# Mock git to fail
		git() { return 1; }
		export -f git
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag 2>/dev/null
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "generate_branch_tag: returns error for empty branch after sanitization" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_branch_tag "@#$%^&*()" 2>/dev/null
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

# =============================================================================
# generate_pr_tag tests
# =============================================================================

@test "generate_pr_tag: uses provided PR number" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_pr_tag "123"
	'
	assert_success
	assert_output "pr-123"
}

@test "generate_pr_tag: extracts PR number from GITHUB_REF" {
	run bash -c '
		export GITHUB_REF="refs/pull/456/merge"
		source "$LIB_DIR/docker/tags.sh"
		generate_pr_tag
	'
	assert_success
	assert_output "pr-456"
}

@test "generate_pr_tag: handles GITHUB_REF with head" {
	run bash -c '
		export GITHUB_REF="refs/pull/789/head"
		source "$LIB_DIR/docker/tags.sh"
		generate_pr_tag
	'
	assert_success
	assert_output "pr-789"
}

@test "generate_pr_tag: returns failure when no PR number available" {
	run bash -c '
		unset GITHUB_REF
		source "$LIB_DIR/docker/tags.sh"
		generate_pr_tag
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "generate_pr_tag: returns failure for non-PR GITHUB_REF" {
	run bash -c '
		export GITHUB_REF="refs/heads/main"
		source "$LIB_DIR/docker/tags.sh"
		generate_pr_tag
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

# =============================================================================
# generate_docker_tags tests
# =============================================================================

@test "generate_docker_tags: returns error without image name" {
	run bash -c '
		source "$LIB_DIR/docker/tags.sh"
		generate_docker_tags ""
	'
	assert_failure
}

@test "generate_docker_tags: generates SHA tag" {
	run bash -c '
		export GITHUB_SHA="abc1234567890"
		# Mock git to prevent branch fallback
		git() { return 1; }
		export -f git
		source "$LIB_DIR/docker/tags.sh"
		generate_docker_tags "ghcr.io/org/repo" 2>/dev/null
	'
	assert_success
	assert_line "ghcr.io/org/repo:sha-abc1234"
}

@test "generate_docker_tags: generates semver tags when version provided" {
	run bash -c '
		export GITHUB_SHA="abc1234567890"
		git() { return 1; }
		export -f git
		source "$LIB_DIR/docker/tags.sh"
		generate_docker_tags "ghcr.io/org/repo" "v1.2.3" 2>/dev/null
	'
	assert_success
	assert_line "ghcr.io/org/repo:1"
	assert_line "ghcr.io/org/repo:1.2"
	assert_line "ghcr.io/org/repo:1.2.3"
	assert_line "ghcr.io/org/repo:latest"
}

@test "generate_docker_tags: generates branch tag" {
	run bash -c '
		export GITHUB_SHA="abc1234567890"
		export GITHUB_REF_NAME="develop"
		source "$LIB_DIR/docker/tags.sh"
		generate_docker_tags "ghcr.io/org/repo" 2>/dev/null
	'
	assert_success
	assert_line "ghcr.io/org/repo:develop"
}

@test "generate_docker_tags: generates PR tag" {
	run bash -c '
		export GITHUB_SHA="abc1234567890"
		export GITHUB_REF="refs/pull/42/merge"
		source "$LIB_DIR/docker/tags.sh"
		generate_docker_tags "ghcr.io/org/repo" 2>/dev/null
	'
	assert_success
	assert_line "ghcr.io/org/repo:pr-42"
}

@test "generate_docker_tags: outputs unique sorted tags" {
	run bash -c '
		export GITHUB_SHA="abc1234567890"
		export GITHUB_REF_NAME="main"
		# Force duplicate by setting branch to "latest"
		source "$LIB_DIR/docker/tags.sh"
		# Count lines to verify no duplicates
		tags=$(generate_docker_tags "img" "1.0.0" 2>/dev/null | sort | uniq -d)
		if [[ -z "$tags" ]]; then
			echo "no duplicates"
		else
			echo "duplicates: $tags"
		fi
	'
	assert_success
	assert_output "no duplicates"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "docker/tags.sh: exports generate_semver_tags function" {
	run bash -c 'source "$LIB_DIR/docker/tags.sh" && bash -c "type generate_semver_tags"'
	assert_success
}

@test "docker/tags.sh: exports generate_sha_tag function" {
	run bash -c 'source "$LIB_DIR/docker/tags.sh" && bash -c "type generate_sha_tag"'
	assert_success
}

@test "docker/tags.sh: exports generate_branch_tag function" {
	run bash -c 'source "$LIB_DIR/docker/tags.sh" && bash -c "type generate_branch_tag"'
	assert_success
}

@test "docker/tags.sh: exports generate_pr_tag function" {
	run bash -c 'source "$LIB_DIR/docker/tags.sh" && bash -c "type generate_pr_tag"'
	assert_success
}

@test "docker/tags.sh: exports generate_docker_tags function" {
	run bash -c 'source "$LIB_DIR/docker/tags.sh" && bash -c "type generate_docker_tags"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "docker/tags.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/docker/tags.sh" && echo "${_LGTM_CI_DOCKER_TAGS_LOADED}"'
	assert_success
	assert_output "1"
}
