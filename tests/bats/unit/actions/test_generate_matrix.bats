#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for generate-matrix.sh E2E and coverage shard steps

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

@test "generate-matrix e2e-matrix: every axis is an array for single and multiple shards" {
	local shards matrix
	for shards in 1 3; do
		: >"${GITHUB_OUTPUT}"
		run env STEP=e2e-matrix SUITES=smoke,visual BROWSERS=chromium,firefox SHARDS="$shards" \
			bash "${SCRIPT}"
		assert_success
		matrix=$(sed -n 's/^matrix=//p' "${GITHUB_OUTPUT}")
		run jq -e 'all(.[]; type == "array")' <<<"$matrix"
		assert_success
		run jq -e --argjson shards "$shards" '
			.suite == ["smoke", "visual"] and
			.browser == ["chromium", "firefox"] and
			.shard == [range(1; $shards + 1) | tostring] and
			(keys | sort) == ["browser", "shard", "suite"]
		' <<<"$matrix"
		assert_success
	done
}

@test "generate-matrix shard-config: gives each leg its place in the total" {
	run env STEP=shard-config SHARD=2 TOTAL_SHARDS=3 bash "${SCRIPT}"
	assert_success
	assert_file_contains_literal "${GITHUB_OUTPUT}" 'config=2/3'
}

@test "generate-matrix shard-config: a shard above the total fails" {
	run env STEP=shard-config SHARD=2 TOTAL_SHARDS=1 bash "${SCRIPT}"
	assert_failure
	assert_output --partial "cannot exceed TOTAL_SHARDS"
}

@test "generate-matrix: the E2E workflow passes inputs.shards as the shard total" {
	# The matrix no longer carries the total (#1446). If this binding is lost,
	# the total defaults to 1 and every leg above shard 1 fails.
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
	run grep -cE '^ +TOTAL_SHARDS: \$\{\{ inputs\.shards \}\}$' "$workflow"
	assert_output "1"
	run grep -c 'matrix\.total_shards' "$workflow"
	assert_output "0"
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
