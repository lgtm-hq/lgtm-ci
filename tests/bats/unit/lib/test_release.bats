#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release.sh (aggregator + high-level functions)

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR

	setup_mock_git_repo
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Helpers add_commit and tag_mock_repo are provided by the shared mocks helper

# =============================================================================
# Aggregator loading tests
# =============================================================================

@test "release.sh: sources release/version.sh" {
	run bash -c 'source "$LIB_DIR/release.sh" && declare -f validate_semver >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "release.sh: sources release/extract.sh" {
	run bash -c 'source "$LIB_DIR/release.sh" && declare -f extract_version_pyproject >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "release.sh: sources release/conventional.sh" {
	run bash -c 'source "$LIB_DIR/release.sh" && declare -f parse_conventional_commit >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "release.sh: sources release/analyze.sh" {
	run bash -c 'source "$LIB_DIR/release.sh" && declare -f analyze_commits_for_bump >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "release.sh: sources release/changelog.sh" {
	run bash -c 'source "$LIB_DIR/release.sh" && declare -f generate_changelog >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "release.sh: sources release/fileops.sh" {
	run bash -c 'source "$LIB_DIR/release.sh" && declare -f update_changelog_file >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# determine_next_version tests
# =============================================================================

@test "determine_next_version: returns minor for feat commit" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && determine_next_version"
	assert_success
	assert_output "1.1.0"
}

@test "determine_next_version: returns patch for fix commit" {
	tag_mock_repo "v1.0.0"
	add_commit "fix: fix bug"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && determine_next_version"
	assert_success
	assert_output "1.0.1"
}

@test "determine_next_version: starts from 0.0.0 when no tags" {
	add_commit "feat: initial feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && determine_next_version"
	assert_success
	assert_output "0.1.0"
}

@test "determine_next_version: returns empty and fails for no releasable commits" {
	tag_mock_repo "v1.0.0"
	add_commit "docs: update readme"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && determine_next_version"
	assert_failure
	assert_output ""
}

@test "determine_next_version: clamps to max_bump" {
	tag_mock_repo "v1.0.0"
	add_commit "feat!: breaking change"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && determine_next_version \"minor\""
	assert_success
	assert_output "1.1.0"
}

# =============================================================================
# create_release tests
# =============================================================================

@test "create_release: creates annotated tag" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && create_release \"1.1.0\""
	assert_success
	assert_output --partial "Created tag: v1.1.0"

	# Verify tag exists
	run bash -c "cd \"$MOCK_GIT_REPO\" && git tag -l v1.1.0"
	assert_output "v1.1.0"
}

@test "create_release: returns 1 for missing version" {
	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && create_release \"\" 2>&1"
	assert_failure
	assert_output --partial "Version required"
}

@test "create_release: strips v prefix from input" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && create_release \"v1.1.0\""
	assert_success
	assert_output --partial "Created tag: v1.1.0"
}

# =============================================================================
# should_release tests
# =============================================================================

@test "should_release: returns true when feat commits exist" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: new feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && should_release && echo \"yes\""
	assert_success
	assert_output "yes"
}

@test "should_release: returns false for docs only" {
	tag_mock_repo "v1.0.0"
	add_commit "docs: update readme"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && should_release || echo \"no\""
	assert_success
	assert_output "no"
}

@test "should_release: uses provided from_ref" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: first feature"
	tag_mock_repo "v1.1.0"
	add_commit "docs: only docs"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && should_release \"v1.1.0\" || echo \"no\""
	assert_success
	assert_output "no"
}

# =============================================================================
# get_release_summary tests
# =============================================================================

@test "get_release_summary: outputs summary format" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add feature"
	add_commit "fix: fix bug"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && get_release_summary"
	assert_success
	assert_output --partial "Latest tag: v1.0.0"
	assert_output --partial "Bump type:"
}

@test "get_release_summary: shows 'none' for no tags" {
	add_commit "feat: add feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release.sh\" && get_release_summary"
	assert_success
	assert_output --partial "Latest tag: none"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "release.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/release.sh"
		source "$LIB_DIR/release.sh"
		declare -f determine_next_version >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "release.sh: sets _RELEASE_LOADED guard" {
	run bash -c 'source "$LIB_DIR/release.sh" && echo "${_RELEASE_LOADED}"'
	assert_success
	assert_output "1"
}
