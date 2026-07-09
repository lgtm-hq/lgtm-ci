#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/ghcr/tags.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# ghcr_is_ephemeral_only_tagged
# =============================================================================

@test "ghcr_is_ephemeral_only_tagged: accepts numeric ephemeral tags" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_ephemeral_only_tagged "[\"pr-42\",\"mq-7\",\"dispatch-99\"]"
	'
	assert_success
}

@test "ghcr_is_ephemeral_only_tagged: accepts non-numeric ephemeral suffixes" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_ephemeral_only_tagged "[\"pr-feature\",\"dispatch-nightly\"]"
	'
	assert_success
}

@test "ghcr_is_ephemeral_only_tagged: rejects mixed ephemeral and permanent tags" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_ephemeral_only_tagged "[\"cache\",\"pr-3\"]"
	'
	assert_failure
}

@test "ghcr_is_ephemeral_only_tagged: rejects permanent-only tags" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_ephemeral_only_tagged "[\"latest\",\"v1.0.0\"]"
	'
	assert_failure
}

@test "ghcr_is_ephemeral_only_tagged: rejects empty tag list" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_ephemeral_only_tagged "[]"
	'
	assert_failure
}

@test "ghcr_is_ephemeral_only_tagged: rejects missing argument as empty list" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_ephemeral_only_tagged
	'
	assert_failure
}

# =============================================================================
# ghcr_is_build_staging_only_tagged
# =============================================================================

@test "ghcr_is_build_staging_only_tagged: accepts build-<run_id>-<slug> tags" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_build_staging_only_tagged "[\"build-123-linux-amd64\"]"
	'
	assert_success
}

@test "ghcr_is_build_staging_only_tagged: accepts multi-segment platform slugs" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_build_staging_only_tagged "[\"build-42-linux-arm-v7\"]"
	'
	assert_success
}

@test "ghcr_is_build_staging_only_tagged: rejects release tags" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_build_staging_only_tagged "[\"v1.0.0\",\"latest\"]"
	'
	assert_failure
}

@test "ghcr_is_build_staging_only_tagged: rejects a version mixing build and release tags" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_build_staging_only_tagged "[\"build-123-linux-amd64\",\"latest\"]"
	'
	assert_failure
}

@test "ghcr_is_build_staging_only_tagged: rejects non-numeric run id" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_build_staging_only_tagged "[\"build-main-linux-amd64\"]"
	'
	assert_failure
}

@test "ghcr_is_build_staging_only_tagged: rejects ephemeral build-cache tags" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_build_staging_only_tagged "[\"pr-42\"]"
	'
	assert_failure
}

@test "ghcr_is_build_staging_only_tagged: rejects empty tag list" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_build_staging_only_tagged "[]"
	'
	assert_failure
}

@test "ghcr/tags.sh: second source is a no-op when already loaded" {
	run bash -c '
		source "$LIB_DIR/ghcr/tags.sh"
		source "$LIB_DIR/ghcr/tags.sh"
		ghcr_is_ephemeral_only_tagged "[\"pr-1\"]"
	'
	assert_success
}
