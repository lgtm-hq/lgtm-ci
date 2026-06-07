#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for aggregate-rust-release-checksums.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/aggregate-rust-release-checksums.sh"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "aggregate-rust-release-checksums: merges per-target manifests" {
	mkdir -p "$BATS_TEST_TMPDIR/dist"
	printf 'aaa  a.tar.gz\n' >"$BATS_TEST_TMPDIR/dist/SHA256SUMS-x86_64-unknown-linux-musl"
	printf 'bbb  b.zip\n' >"$BATS_TEST_TMPDIR/dist/SHA256SUMS-x86_64-pc-windows-msvc"

	run env ARTIFACT_PATH="$BATS_TEST_TMPDIR/dist" bash "$SCRIPT"
	assert_success

	[[ -f "$BATS_TEST_TMPDIR/dist/SHA256SUMS" ]]
	[[ ! -f "$BATS_TEST_TMPDIR/dist/SHA256SUMS-x86_64-unknown-linux-musl" ]]
	[[ ! -f "$BATS_TEST_TMPDIR/dist/SHA256SUMS-x86_64-pc-windows-msvc" ]]
	run grep -c . "$BATS_TEST_TMPDIR/dist/SHA256SUMS"
	assert_success
	assert_equal 2 "$output"
}

@test "aggregate-rust-release-checksums: fails when no manifests exist" {
	mkdir -p "$BATS_TEST_TMPDIR/dist"
	run env ARTIFACT_PATH="$BATS_TEST_TMPDIR/dist" bash "$SCRIPT"
	assert_failure
	assert_output --partial "No per-target checksum manifests"
}
