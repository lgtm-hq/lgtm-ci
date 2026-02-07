#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/github/format.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# get_github_pages_url tests
# =============================================================================

@test "get_github_pages_url: constructs correct URL for repo with path" {
	run bash -c '
		export GITHUB_REPOSITORY="lgtm-hq/turbo-themes"
		source "$LIB_DIR/github/format.sh"
		get_github_pages_url "playwright"
	'
	assert_success
	assert_output "https://lgtm-hq.github.io/turbo-themes/playwright/"
}

@test "get_github_pages_url: constructs correct URL without path" {
	run bash -c '
		export GITHUB_REPOSITORY="my-org/my-repo"
		source "$LIB_DIR/github/format.sh"
		get_github_pages_url ""
	'
	assert_success
	assert_output "https://my-org.github.io/my-repo/"
}

@test "get_github_pages_url: handles user pages repo (owner.github.io)" {
	run bash -c '
		export GITHUB_REPOSITORY="alice/alice.github.io"
		source "$LIB_DIR/github/format.sh"
		get_github_pages_url ""
	'
	assert_success
	assert_output "https://alice.github.io/"
}

@test "get_github_pages_url: lowercases owner in URL" {
	run bash -c '
		export GITHUB_REPOSITORY="MyOrg/MyRepo"
		source "$LIB_DIR/github/format.sh"
		get_github_pages_url "docs"
	'
	assert_success
	assert_output "https://myorg.github.io/myrepo/docs/"
}

@test "get_github_pages_url: accepts explicit repo parameter" {
	run bash -c '
		source "$LIB_DIR/github/format.sh"
		get_github_pages_url "coverage" "other-org/other-repo"
	'
	assert_success
	assert_output "https://other-org.github.io/other-repo/coverage/"
}

@test "get_github_pages_url: returns empty and fails when no repo available" {
	run bash -c '
		unset GITHUB_REPOSITORY
		source "$LIB_DIR/github/format.sh"
		get_github_pages_url "test"
	'
	assert_failure
	assert_output ""
}

@test "get_github_pages_url: handles repo without slash (uses as both owner and name)" {
	# When repo has no slash, the function uses the whole string as both owner and name
	run bash -c '
		source "$LIB_DIR/github/format.sh"
		get_github_pages_url "test" "myrepo"
	'
	assert_success
	assert_output "https://myrepo.github.io/myrepo/test/"
}

# =============================================================================
# score_emoji tests
# =============================================================================

@test "score_emoji: returns green for score meeting threshold" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 85 80'
	assert_success
	assert_output "🟢"
}

@test "score_emoji: returns green for score exactly at threshold" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 80 80'
	assert_success
	assert_output "🟢"
}

@test "score_emoji: returns yellow for score within 10 of threshold" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 75 80'
	assert_success
	assert_output "🟡"
}

@test "score_emoji: returns red for score far below threshold" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 50 80'
	assert_success
	assert_output "🔴"
}

@test "score_emoji: handles fractional scores by truncating" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 79.9 80'
	assert_success
	assert_output "🟡"
}

@test "score_emoji: returns white for empty score" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji ""'
	assert_success
	assert_output "⚪"
}

@test "score_emoji: returns white for non-numeric score" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji "N/A"'
	assert_success
	assert_output "⚪"
}

@test "score_emoji: defaults threshold to 80 when not provided" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 80'
	assert_success
	assert_output "🟢"
}

@test "score_emoji: handles zero score" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 0 80'
	assert_success
	assert_output "🔴"
}

@test "score_emoji: handles 100 score" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 100 80'
	assert_success
	assert_output "🟢"
}

@test "score_emoji: warn threshold doesn't go negative for low thresholds" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && score_emoji 5 5'
	assert_success
	assert_output "🟢"
}

# =============================================================================
# format_score_with_color tests
# =============================================================================

@test "format_score_with_color: formats high score with green" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_score_with_color 95'
	assert_success
	assert_output "🟢 95"
}

@test "format_score_with_color: formats medium score with yellow" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_score_with_color 72 80'
	assert_success
	assert_output "🟡 72"
}

@test "format_score_with_color: formats low score with red" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_score_with_color 40 80'
	assert_success
	assert_output "🔴 40"
}

@test "format_score_with_color: handles N/A" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_score_with_color "N/A"'
	assert_success
	assert_output "⚪ N/A"
}

@test "format_score_with_color: handles empty input" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_score_with_color ""'
	assert_success
	assert_output "⚪ N/A"
}

@test "format_score_with_color: preserves decimal for display" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_score_with_color 85.5 80'
	assert_success
	assert_output "🟢 85.5"
}

# =============================================================================
# format_percentage_with_color tests
# =============================================================================

@test "format_percentage_with_color: formats with percent sign" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_percentage_with_color 90'
	assert_success
	assert_output "🟢 90%"
}

@test "format_percentage_with_color: handles decimal percentages" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_percentage_with_color 75.5 80'
	assert_success
	assert_output "🟡 75.5%"
}

@test "format_percentage_with_color: handles N/A" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_percentage_with_color "N/A"'
	assert_success
	assert_output "⚪ N/A"
}

@test "format_percentage_with_color: uses custom threshold" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_percentage_with_color 50 50'
	assert_success
	assert_output "🟢 50%"
}

@test "format_percentage_with_color: red for far below threshold" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && format_percentage_with_color 10 80'
	assert_success
	assert_output "🔴 10%"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "github/format.sh: exports get_github_pages_url function" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && bash -c "type get_github_pages_url"'
	assert_success
}

@test "github/format.sh: exports score_emoji function" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && bash -c "type score_emoji"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "github/format.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/github/format.sh" && echo "${_LGTM_CI_GITHUB_FORMAT_LOADED}"'
	assert_success
	assert_output "1"
}
