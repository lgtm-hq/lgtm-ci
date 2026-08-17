#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for generate-matrix.sh coverage-shards step (#874)

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/generate-matrix.sh"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"
}

teardown() {
	teardown_temp_dir
}

@test "generate-matrix coverage-shards: emits 0-based shard JSON" {
	run env STEP=coverage-shards SHARD_TOTAL=4 GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
		bash "${SCRIPT}"
	assert_success
	assert_file_contains_literal "${GITHUB_OUTPUT}" 'matrix={"shard":[0,1,2,3]}'
}

@test "generate-matrix coverage-shards: SHARD_TOTAL=1 is a single shard" {
	run env STEP=coverage-shards SHARD_TOTAL=1 GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
		bash "${SCRIPT}"
	assert_success
	assert_file_contains_literal "${GITHUB_OUTPUT}" 'matrix={"shard":[0]}'
}

@test "generate-matrix coverage-shards: rejects non-positive totals" {
	run env STEP=coverage-shards SHARD_TOTAL=0 GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
		bash "${SCRIPT}"
	assert_failure
	assert_output --partial "SHARD_TOTAL must be a positive integer"
}

@test "generate-matrix coverage-shards: rejects totals above 256" {
	run env STEP=coverage-shards SHARD_TOTAL=257 GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
		bash "${SCRIPT}"
	assert_failure
	assert_output --partial "GitHub matrix limit of 256"
}
