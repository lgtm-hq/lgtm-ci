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
# Line-wrapping tests (issue #417)
# =============================================================================

# Longest line in the given multi-line text
_max_line_length() {
	awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'
}

@test "wrap_changelog_line: short line is returned unchanged" {
	run bash -c 'source "$LIB_DIR/release/changelog.sh" && wrap_changelog_line "- short entry (abc1234)"'
	assert_success
	assert_output "- short entry (abc1234)"
}

@test "wrap_changelog_line: long line wraps to <= 88 columns" {
	local long="- **release**: add source-ref and tag-latest inputs for historical backfill of previously unreleased Docker multi-arch images (abc1234)"
	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && wrap_changelog_line '$long'"
	assert_success
	local max
	max=$(printf '%s\n' "$output" | _max_line_length)
	[ "$max" -le 88 ]
}

@test "wrap_changelog_line: continuation lines use two-space indent" {
	local long="- **release**: add source-ref and tag-latest inputs for historical backfill of previously unreleased Docker multi-arch images (abc1234)"
	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && wrap_changelog_line '$long'"
	assert_success
	# First line keeps the list marker; the continuation is indented two spaces
	assert_line --index 0 "- **release**: add source-ref and tag-latest inputs for historical backfill of"
	assert_line --index 1 "  previously unreleased Docker multi-arch images (abc1234)"
}

@test "wrap_changelog_line: unbreakable long token overflows onto its own line" {
	local url="https://example.com/really/long/path/that/keeps/going/and/going/and/going/way/past/eighty/eight/columns/xyz"
	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && wrap_changelog_line '- **deps**: ${url} (ccc3333)'"
	assert_success
	# The token is not split; it appears intact on its own indented line
	assert_output --partial "  ${url}"
}

@test "wrap_changelog_line: wrapping is idempotent for already-short input" {
	run bash -c '
		source "$LIB_DIR/release/changelog.sh"
		first=$(wrap_changelog_line "- short entry (abc1234)")
		second=$(wrap_changelog_line "$first")
		[ "$first" = "$second" ] && echo ok'
	assert_success
	assert_output "ok"
}

@test "wrap_changelog_line: wrapping is idempotent for already-wrapped input" {
	run bash -c '
		source "$LIB_DIR/release/changelog.sh"
		long="- **release**: add source-ref and tag-latest inputs for historical backfill of previously unreleased Docker multi-arch images (abc1234)"
		first=$(wrap_changelog_line "$long")
		second=$(wrap_changelog_line "$first")
		line_count=$(printf "%s\n" "$first" | wc -l | tr -d " ")
		[ "$line_count" -gt 1 ] && [ "$first" = "$second" ] && echo ok'
	assert_success
	assert_output "ok"
}

@test "wrap_changelog_line: honors CHANGELOG_LINE_LENGTH override" {
	run bash -c '
		source "$LIB_DIR/release/changelog.sh"
		CHANGELOG_LINE_LENGTH=40 wrap_changelog_line "- one two three four five six seven eight nine ten"'
	assert_success
	local max
	max=$(printf '%s\n' "$output" | _max_line_length)
	[ "$max" -le 40 ]
}

@test "format_commit_entry: long full entry wraps to <= 88 columns" {
	local desc="add source-ref and tag-latest inputs for historical backfill of previously unreleased Docker multi-arch images"
	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && format_commit_entry 'abc1234567' 'feat' 'release' '$desc' 'full'"
	assert_success
	local max
	max=$(printf '%s\n' "$output" | _max_line_length)
	[ "$max" -le 88 ]
	assert_output --partial "- **release**:"
	assert_output --partial "(abc1234)"
}

@test "generate_changelog: all emitted lines are <= 88 columns for long titles" {
	tag_mock_repo "v1.0.0"
	add_commit "feat(release): add source-ref and tag-latest inputs for historical backfill of previously unreleased Docker multi-arch images"
	add_commit "fix: resolve a crash that happened when the configuration file contained a deeply nested structure with many keys"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.1.0\""
	assert_success
	local max
	max=$(printf '%s\n' "$output" | _max_line_length)
	[ "$max" -le 88 ]
}

@test "generate_changelog: short titles remain on a single line" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add search"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.1.0\""
	assert_success
	# Short entry is not wrapped: the whole bullet stays on one line
	assert_output --partial "- add search"
	refute_output --partial $'\n  '
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

	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog_section \"Added\" '$commits' \"full\""
	assert_success
	assert_output --partial "### Added"
	assert_output --partial "add login"
	assert_output --partial "add logout"
}

@test "generate_changelog_section: uses simple format" {
	local commits
	commits=$(printf 'abc1234567\x1Ffix\x1F\x1Ffix bug')

	run bash -c "source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog_section \"Fixed\" '$commits' \"simple\""
	assert_success
	assert_output --partial "### Fixed"
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

@test "generate_changelog: includes added section" {
	tag_mock_repo "v1.0.0"
	add_commit "feat: add search"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.1.0\""
	assert_success
	assert_output --partial "### Added"
	assert_output --partial "add search"
}

@test "generate_changelog: includes fixed section" {
	tag_mock_repo "v1.0.0"
	add_commit "fix: resolve crash"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.0.1\""
	assert_success
	assert_output --partial "### Fixed"
	assert_output --partial "resolve crash"
}

@test "generate_changelog: includes breaking changes under Changed" {
	tag_mock_repo "v1.0.0"
	add_commit "feat!: new API"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"2.0.0\""
	assert_success
	assert_output --partial "### Changed"
	assert_output --partial "new API"
}

@test "generate_changelog: includes other changes under Changed in full format" {
	tag_mock_repo "v1.0.0"
	add_commit "chore: update deps"

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/changelog.sh\" && generate_changelog \"v1.0.0\" \"HEAD\" \"1.0.1\" \"full\""
	assert_success
	assert_output --partial "### Changed"
	assert_output --partial "update deps"
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
