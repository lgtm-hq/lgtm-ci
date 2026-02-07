#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/changelog.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

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
# format_commit_entry tests
# =============================================================================

@test "format_commit_entry: full format with scope" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && format_commit_entry "abc1234567" "feat" "auth" "add login" "full"'
	assert_success
	assert_output "- **auth**: add login (abc1234)"
}

@test "format_commit_entry: full format without scope" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && format_commit_entry "abc1234567" "feat" "" "add login" "full"'
	assert_success
	assert_output "- add login (abc1234)"
}

@test "format_commit_entry: simple format" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && format_commit_entry "abc1234567" "feat" "auth" "add login" "simple"'
	assert_success
	assert_output "- add login"
}

@test "format_commit_entry: with-type format and scope" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && format_commit_entry "abc1234567" "feat" "auth" "add login" "with-type"'
	assert_success
	assert_output "- feat(auth): add login"
}

@test "format_commit_entry: with-type format without scope" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && format_commit_entry "abc1234567" "fix" "" "resolve crash" "with-type"'
	assert_success
	assert_output "- fix: resolve crash"
}

@test "format_commit_entry: unknown format defaults to full without scope" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && format_commit_entry "abc1234567" "feat" "" "add login" "unknown"'
	assert_success
	assert_output "- add login (abc1234)"
}

# =============================================================================
# generate_changelog_section tests
# =============================================================================

@test "generate_changelog_section: returns nothing for empty data" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && generate_changelog_section "Features" ""'
	assert_success
	assert_output ""
}

@test "generate_changelog_section: generates section with commits" {
	local commits
	commits=$(printf 'abc1234567\x1Ffeat\x1Fauth\x1Fadd login\nabc1234568\x1Ffeat\x1F\x1Fadd logout')

	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog_section \"Features\" '$commits' \"full\""
	assert_success
	assert_output --partial "### Features"
	assert_output --partial "add login"
	assert_output --partial "add logout"
}

@test "generate_changelog_section: uses simple format" {
	local commits
	commits=$(printf 'abc1234567\x1Ffix\x1F\x1Ffix bug')

	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog_section \"Bug Fixes\" '$commits' \"simple\""
	assert_success
	assert_output --partial "### Bug Fixes"
	assert_output --partial "- fix bug"
}

# =============================================================================
# generate_changelog tests
# =============================================================================

@test "generate_changelog: generates header with version" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.1.0\""
	assert_success
	assert_output --partial "## [1.1.0]"
}

@test "generate_changelog: generates Unreleased header without version" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"\""
	assert_success
	assert_output --partial "## Unreleased"
}

@test "generate_changelog: includes features section" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add search"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.1.0\""
	assert_success
	assert_output --partial "### Features"
	assert_output --partial "add search"
}

@test "generate_changelog: includes bug fixes section" {
	tag_mock_repo "v1.0.0"
	add_commit "fix: resolve crash"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.0.1\""
	assert_success
	assert_output --partial "### Bug Fixes"
	assert_output --partial "resolve crash"
}

@test "generate_changelog: includes breaking changes section" {
	tag_mock_repo "v1.0.0"
	add_commit "feat!: new API"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"2.0.0\""
	assert_success
	assert_output --partial "### Breaking Changes"
}

@test "generate_changelog: includes other changes in full format" {
	tag_mock_repo "v1.0.0"
	add_commit "chore: update deps"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.0.1\" \"full\""
	assert_success
	assert_output --partial "### Other Changes"
}

# =============================================================================
# generate_release_notes tests
# =============================================================================

@test "generate_release_notes: includes summary line" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add feature"
	add_commit "fix: fix bug"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_release_notes \"v1.0.0\" \"HEAD\" \"1.1.0\""
	assert_success
	assert_output --partial "This release includes:"
	assert_output --partial "1 feature(s)"
	assert_output --partial "1 fix(es)"
}

@test "generate_release_notes: uses simple format for changelog" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: new feature"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_release_notes \"v1.0.0\" \"HEAD\" \"1.1.0\""
	assert_success
	# Simple format uses "- description" without sha
	assert_output --partial "- new feature"
}

@test "generate_release_notes: shows breaking changes in summary" {
	tag_mock_repo "v1.0.0"
	add_commit "feat!: breaking thing"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_release_notes \"v1.0.0\" \"HEAD\" \"2.0.0\""
	assert_success
	assert_output --partial "breaking change(s)"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "changelog.sh: exports format_commit_entry function" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && declare -f format_commit_entry >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "changelog.sh: exports generate_changelog function" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && declare -f generate_changelog >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "changelog.sh: exports generate_release_notes function" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && declare -f generate_release_notes >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "changelog.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/release/changelog.sh"
		source "$LIB_DIR/release/changelog.sh"
		declare -f format_commit_entry >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "changelog.sh: sets _RELEASE_CHANGELOG_LOADED guard" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && echo "${_RELEASE_CHANGELOG_LOADED}"'
	assert_success
	assert_output "1"
}
