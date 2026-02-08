#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/analyze.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR

	# Setup a git repo for most tests
	setup_mock_git_repo
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Helpers add_commit and tag_mock_repo are provided by the shared mocks helper

# =============================================================================
# analyze_commits_for_bump tests
# =============================================================================

@test "analyze_commits_for_bump: detects major bump from breaking change (!)" {
	tag_mock_repo "v1.0.0"
	add_commit "feat!: redesign API"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output "major"
}

@test "analyze_commits_for_bump: detects major bump from BREAKING CHANGE in body" {
	tag_mock_repo "v1.0.0"
	(cd "$MOCK_GIT_REPO" && git commit -q --allow-empty -m "feat: new thing

BREAKING CHANGE: old API removed")

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output "major"
}

@test "analyze_commits_for_bump: detects minor bump from feat" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add new feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output "minor"
}

@test "analyze_commits_for_bump: detects patch bump from fix" {
	tag_mock_repo "v1.0.0"
	add_commit "fix: resolve crash"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output "patch"
}

@test "analyze_commits_for_bump: returns none for docs/chore only" {
	tag_mock_repo "v1.0.0"
	add_commit "docs: update readme"
	add_commit "chore: update deps"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output "none"
}

@test "analyze_commits_for_bump: returns none for invalid from_ref" {
	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"nonexistent-tag\" \"HEAD\""
	assert_success
	assert_output "none"
}

@test "analyze_commits_for_bump: major takes priority over minor and patch" {
	tag_mock_repo "v1.0.0"
	add_commit "fix: fix bug"
	add_commit "feat: add feature"
	add_commit "feat!: breaking change"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output "major"
}

@test "analyze_commits_for_bump: minor takes priority over patch" {
	tag_mock_repo "v1.0.0"
	add_commit "fix: fix bug"
	add_commit "feat: add feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output "minor"
}

@test "analyze_commits_for_bump: empty from_ref analyzes all commits" {
	add_commit "feat: new thing"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && analyze_commits_for_bump \"\" \"HEAD\""
	assert_success
	assert_output "minor"
}

# =============================================================================
# get_commits_by_type tests
# =============================================================================

@test "get_commits_by_type: groups commits into sections" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add login"
	add_commit "fix: fix crash"
	add_commit "docs: update api docs"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && get_commits_by_type \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output --partial "### BREAKING"
	assert_output --partial "### FEATURES"
	assert_output --partial "### FIXES"
	assert_output --partial "### DOCS"
	assert_output --partial "### OTHER"
	assert_output --partial "add login"
	assert_output --partial "fix crash"
	assert_output --partial "update api docs"
}

@test "get_commits_by_type: returns empty sections for invalid ref" {
	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && get_commits_by_type \"nonexistent\" \"HEAD\""
	assert_success
	assert_output --partial "### BREAKING"
	assert_output --partial "### FEATURES"
}

@test "get_commits_by_type: categorizes non-conventional commits as other" {
	tag_mock_repo "v1.0.0"
	add_commit "random commit message"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && get_commits_by_type \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output --partial "random commit message"
}

@test "get_commits_by_type: handles scoped commits" {
	tag_mock_repo "v1.0.0"
	add_commit "feat(auth): add oauth"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && get_commits_by_type \"v1.0.0\" \"HEAD\""
	assert_success
	assert_output --partial "add oauth"
}

@test "get_commits_by_type: uses FIELD_SEP delimiter" {
	tag_mock_repo "v1.0.0"
	add_commit "feat(ui): add button"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && get_commits_by_type \"v1.0.0\" \"HEAD\" | cat -v"
	assert_success
	# Unit separator (0x1F) shows as ^_ in cat -v
	assert_output --partial "^_"
}

# =============================================================================
# count_commits_by_type tests
# =============================================================================

@test "count_commits_by_type: counts correctly" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: feature one"
	add_commit "feat: feature two"
	add_commit "fix: a bug"
	add_commit "docs: update docs"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && count_commits_by_type \"v1.0.0\" \"HEAD\""
	assert_success
	assert_line "features=2"
	assert_line "fixes=1"
	assert_line "docs=1"
}

@test "count_commits_by_type: returns zeros for invalid ref" {
	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && count_commits_by_type \"nonexistent\" \"HEAD\""
	assert_success
	assert_line "breaking=0"
	assert_line "features=0"
	assert_line "fixes=0"
	assert_line "docs=0"
	assert_line "other=0"
}

@test "count_commits_by_type: counts breaking changes" {
	tag_mock_repo "v1.0.0"
	add_commit "feat!: breaking feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && count_commits_by_type \"v1.0.0\" \"HEAD\""
	assert_success
	assert_line "breaking=1"
}

# =============================================================================
# has_releasable_commits tests
# =============================================================================

@test "has_releasable_commits: returns true when feat commits exist" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: new feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && has_releasable_commits \"v1.0.0\" \"HEAD\" && echo \"yes\""
	assert_success
	assert_output "yes"
}

@test "has_releasable_commits: returns false when only docs" {
	tag_mock_repo "v1.0.0"
	add_commit "docs: readme update"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && has_releasable_commits \"v1.0.0\" \"HEAD\" || echo \"no\""
	assert_success
	assert_output "no"
}

@test "has_releasable_commits: returns true for fix commits" {
	tag_mock_repo "v1.0.0"
	add_commit "fix: resolve issue"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/analyze.sh\" && has_releasable_commits \"v1.0.0\" \"HEAD\" && echo \"yes\""
	assert_success
	assert_output "yes"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "analyze.sh: exports analyze_commits_for_bump function" {
	run bash -c 'source "$LIB_DIR/release/analyze.sh" && declare -f analyze_commits_for_bump >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "analyze.sh: exports get_commits_by_type function" {
	run bash -c 'source "$LIB_DIR/release/analyze.sh" && declare -f get_commits_by_type >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "analyze.sh: exports count_commits_by_type function" {
	run bash -c 'source "$LIB_DIR/release/analyze.sh" && declare -f count_commits_by_type >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "analyze.sh: exports has_releasable_commits function" {
	run bash -c 'source "$LIB_DIR/release/analyze.sh" && declare -f has_releasable_commits >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "analyze.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/release/analyze.sh"
		source "$LIB_DIR/release/analyze.sh"
		declare -f analyze_commits_for_bump >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "analyze.sh: sets _RELEASE_ANALYZE_LOADED guard" {
	run bash -c 'source "$LIB_DIR/release/analyze.sh" && echo "${_RELEASE_ANALYZE_LOADED}"'
	assert_success
	assert_output "1"
}
