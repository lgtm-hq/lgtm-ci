#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/ghcr/retention.sh tagged retention policy

load "../../../../helpers/common"

# Fixed clock so age assertions never drift. The "version" timestamps below are
# expressed relative to these cutoffs, not to today.
MAIN_CUTOFF="2024-06-01T00:00:00Z"
PRERELEASE_CUTOFF="2024-04-01T00:00:00Z"
AGED="2024-01-01T00:00:00Z"   # older than both cutoffs
RECENT="2024-12-01T00:00:00Z" # newer than both cutoffs
# Older than the main cutoff but still inside the pre-release window.
BETWEEN="2024-05-01T00:00:00Z"

setup() {
	setup_temp_dir
	export LIB_DIR
	export MAIN_CUTOFF PRERELEASE_CUTOFF AGED RECENT BETWEEN
}

teardown() {
	teardown_temp_dir
}

classify() {
	run bash -c '
		source "$LIB_DIR/ghcr/retention.sh"
		ghcr_tag_retention_class "$1"
	' _ "$1"
}

deletable() {
	run bash -c '
		source "$LIB_DIR/ghcr/retention.sh"
		ghcr_tag_is_deletable "$1" "$2" "$MAIN_CUTOFF" "$PRERELEASE_CUTOFF"
	' _ "$1" "$2"
}

all_deletable() {
	run bash -c '
		source "$LIB_DIR/ghcr/retention.sh"
		ghcr_all_tags_deletable "$1" "$2" "$MAIN_CUTOFF" "$PRERELEASE_CUTOFF"
	' _ "$1" "$2"
}

# =============================================================================
# ghcr_tag_retention_class
# =============================================================================

@test "ghcr_tag_retention_class: latest is permanent" {
	classify "latest"
	assert_success
	assert_output "permanent"
}

@test "ghcr_tag_retention_class: semver major is permanent" {
	classify "1"
	assert_success
	assert_output "permanent"
}

@test "ghcr_tag_retention_class: semver major.minor is permanent" {
	classify "1.2"
	assert_success
	assert_output "permanent"
}

@test "ghcr_tag_retention_class: semver major.minor.patch is permanent" {
	classify "1.2.3"
	assert_success
	assert_output "permanent"
}

@test "ghcr_tag_retention_class: v-prefixed semver is permanent" {
	classify "v1.2.3"
	assert_success
	assert_output "permanent"
}

@test "ghcr_tag_retention_class: main is main class" {
	classify "main"
	assert_success
	assert_output "main"
}

@test "ghcr_tag_retention_class: sha- tag is main class" {
	classify "sha-abc1234"
	assert_success
	assert_output "main"
}

@test "ghcr_tag_retention_class: bare sha- prefix is not main class" {
	classify "sha-"
	assert_success
	assert_output "unknown"
}

@test "ghcr_tag_retention_class: alpha tag is prerelease" {
	classify "1.2.3-alpha.1"
	assert_success
	assert_output "prerelease"
}

@test "ghcr_tag_retention_class: beta tag is prerelease" {
	classify "2.0.0-beta"
	assert_success
	assert_output "prerelease"
}

@test "ghcr_tag_retention_class: rc tag is prerelease" {
	classify "1.2.3-rc1"
	assert_success
	assert_output "prerelease"
}

@test "ghcr_tag_retention_class: pre tag is prerelease" {
	classify "1.0.0-pre.2"
	assert_success
	assert_output "prerelease"
}

@test "ghcr_tag_retention_class: bare dev tag is prerelease" {
	classify "dev"
	assert_success
	assert_output "prerelease"
}

@test "ghcr_tag_retention_class: snapshot tag is prerelease" {
	classify "3.1.0-snapshot"
	assert_success
	assert_output "prerelease"
}

@test "ghcr_tag_retention_class: unrecognised tag is unknown" {
	classify "release-candidate-review"
	assert_success
	assert_output "unknown"
}

@test "ghcr_tag_retention_class: prerelease match is anchored, not substring" {
	# `predeploy` starts with `pre` but is not the pre-release channel. The
	# fail-safe direction is `unknown` (never deleted).
	classify "predeploy"
	assert_success
	assert_output "unknown"
}

@test "ghcr_tag_retention_class: empty tag is unknown" {
	classify ""
	assert_success
	assert_output "unknown"
}

# =============================================================================
# ghcr_tag_is_deletable - age boundaries per class
# =============================================================================

@test "ghcr_tag_is_deletable: latest is never deletable however old" {
	deletable "latest" "$AGED"
	assert_failure
}

@test "ghcr_tag_is_deletable: semver is never deletable however old" {
	deletable "1.2.3" "$AGED"
	assert_failure
}

@test "ghcr_tag_is_deletable: unrecognised tag is never deletable however old" {
	deletable "release-candidate-review" "$AGED"
	assert_failure
}

@test "ghcr_tag_is_deletable: aged main tag is deletable" {
	deletable "main" "$AGED"
	assert_success
}

@test "ghcr_tag_is_deletable: recent main tag is retained" {
	deletable "main" "$RECENT"
	assert_failure
}

@test "ghcr_tag_is_deletable: aged sha- tag is deletable" {
	deletable "sha-abc1234" "$AGED"
	assert_success
}

@test "ghcr_tag_is_deletable: recent sha- tag is retained" {
	deletable "sha-abc1234" "$RECENT"
	assert_failure
}

@test "ghcr_tag_is_deletable: prerelease past its longer window is deletable" {
	deletable "1.2.3-rc1" "$AGED"
	assert_success
}

@test "ghcr_tag_is_deletable: prerelease within its window is retained" {
	deletable "1.2.3-rc1" "$RECENT"
	assert_failure
}

@test "ghcr_tag_is_deletable: prerelease uses the longer window, not the main one" {
	# Older than the main cutoff but still inside the pre-release window.
	deletable "1.2.3-beta" "$BETWEEN"
	assert_failure
	deletable "main" "$BETWEEN"
	assert_success
}

@test "ghcr_tag_is_deletable: missing timestamp keeps the tag" {
	deletable "main" ""
	assert_failure
}

@test "ghcr_tag_is_deletable: unparseable timestamp keeps the tag" {
	# A shape the lexicographic comparison cannot order safely must never
	# produce a deletion. Retention is the fail-safe direction.
	deletable "main" "not-a-timestamp"
	assert_failure
	deletable "main" "2024-01-01 00:00:00"
	assert_failure
	deletable "main" "2024-01-01T00:00:00+00:00"
	assert_failure
}

@test "ghcr_tag_is_deletable: structurally invalid calendar values keep the tag" {
	# A zeroed or out-of-range field sorts before every real cutoff, so a naive
	# shape check would delete on garbage. Retention is the fail-safe direction.
	deletable "main" "0000-00-00T00:00:00Z"
	assert_failure
	deletable "main" "2024-13-01T00:00:00Z"
	assert_failure
	deletable "main" "2024-01-32T00:00:00Z"
	assert_failure
	deletable "main" "2024-01-01T24:00:00Z"
	assert_failure
	deletable "main" "2024-01-01T00:60:00Z"
	assert_failure
	deletable "main" "2024-01-01T00:00:60Z"
	assert_failure
}

@test "ghcr_tag_is_deletable: a fractional cutoff is normalised too, not just the version" {
	# `Z` sorts after `.`, so normalising only the version side would make a
	# bare `...00Z` compare greater than a fractional `...00.5Z` cutoff and
	# silently retain a version that is genuinely older.
	run bash -c '
		source "$LIB_DIR/ghcr/retention.sh"
		ghcr_tag_is_deletable "main" "2024-05-31T23:59:59Z" \
			"2024-06-01T00:00:00.500Z" "$PRERELEASE_CUTOFF"
	'
	assert_success

	# And the same second on both sides still compares equal, so it is kept.
	run bash -c '
		source "$LIB_DIR/ghcr/retention.sh"
		ghcr_tag_is_deletable "main" "2024-06-01T00:00:00Z" \
			"2024-06-01T00:00:00.500Z" "$PRERELEASE_CUTOFF"
	'
	assert_failure
}

@test "ghcr_tag_is_deletable: fractional seconds do not straddle the cutoff" {
	# Same second as the cutoff: not strictly older, so it is kept, with or
	# without a fractional part. A millisecond must not decide a deletion.
	deletable "main" "$MAIN_CUTOFF"
	assert_failure
	deletable "main" "2024-06-01T00:00:00.999Z"
	assert_failure

	# One second older, with a fractional part: genuinely past the cutoff.
	deletable "main" "2024-05-31T23:59:59.001Z"
	assert_success
}

# =============================================================================
# ghcr_all_tags_deletable - THE RULE THAT MUST NOT BE INVERTED
# =============================================================================

@test "ghcr_all_tags_deletable: ALL tags must agree - one keep tag retains the whole version" {
	# This is the safety property of the entire feature, stated three ways.
	#
	# A release build publishes latest + semver + sha-<commit> onto ONE
	# manifest. The sha- tag is long past the main cutoff, so a naive
	# "delete if ANY tag is deletable" rule would delete this version and
	# take :latest and :1.2.3 down with it - registry corruption.
	#
	# If this test ever needs "fixing", the policy has been inverted. Fix the
	# policy, not the test.
	all_deletable '["latest","1.2.3","sha-abc1234"]' "$AGED"
	assert_failure

	# Same rule with the keep tag in each other position.
	all_deletable '["sha-abc1234","latest"]' "$AGED"
	assert_failure
	all_deletable '["sha-abc1234","1.2.3"]' "$AGED"
	assert_failure

	# And with a merely unrecognised tag as the sole dissenter.
	all_deletable '["sha-abc1234","release-candidate-review"]' "$AGED"
	assert_failure

	# And with an in-retention sibling tag as the sole dissenter: `main` has
	# moved on but this manifest was refreshed recently.
	all_deletable '["sha-abc1234","1.2.3-rc1"]' "$BETWEEN"
	assert_failure
}

@test "ghcr_all_tags_deletable: lone aged sha- version is deleted" {
	all_deletable '["sha-abc1234"]' "$AGED"
	assert_success
}

@test "ghcr_all_tags_deletable: main-push manifest (main + sha-) is deleted once aged" {
	all_deletable '["main","sha-abc1234"]' "$AGED"
	assert_success
}

@test "ghcr_all_tags_deletable: lone latest version is retained" {
	all_deletable '["latest"]' "$AGED"
	assert_failure
}

@test "ghcr_all_tags_deletable: aged prerelease-only version is deleted" {
	all_deletable '["1.2.3-rc1","1.2.3-beta"]' "$AGED"
	assert_success
}

@test "ghcr_all_tags_deletable: unrecognised tag alone is never deleted" {
	all_deletable '["custom-channel"]' "$AGED"
	assert_failure
}

@test "ghcr_all_tags_deletable: untagged version is not this pruner's business" {
	all_deletable '[]' "$AGED"
	assert_failure
}

@test "ghcr_all_tags_deletable: malformed tag payload is retained" {
	all_deletable 'not-json' "$AGED"
	assert_failure
}
