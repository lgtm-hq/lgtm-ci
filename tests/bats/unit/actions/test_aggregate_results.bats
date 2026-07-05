#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/aggregate-results.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	touch "$GITHUB_OUTPUT"
	cd "$BATS_TEST_TMPDIR" || exit 1
}

teardown() {
	teardown_temp_dir
}

_write_summary() {
	local results_dir="$1"
	local key="$2"
	local value="$3"
	local passed="$4"
	local failed="$5"
	local total="$6"
	local coverage="$7"
	local all_passed="$8"
	local dir="${results_dir}/${results_dir}-${value}"

	mkdir -p "$dir"
	cat >"${dir}/summary.json" <<EOF
{
  "coverage-percent": "${coverage}",
  "passed": "${all_passed}",
  "${key}": "${value}",
  "tests-failed": "${failed}",
  "tests-passed": "${passed}",
  "tests-total": "${total}"
}
EOF
}

@test "aggregate-results: sums python metrics across matrix summaries" {
	_write_summary python-results python-version "3.12" 5 1 6 80.00 true
	_write_summary python-results python-version "3.14" 7 0 7 90.00 true

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=12"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=13"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.00"
	assert_file_contains "$GITHUB_OUTPUT" "passed=true"
}

@test "aggregate-results: sums rust metrics across matrix summaries" {
	_write_summary rust-results rust-toolchain "stable" 5 1 6 80.00 true
	_write_summary rust-results rust-toolchain "beta" 7 0 7 90.00 true

	run env RESULTS_DIR=rust-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=12"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=13"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.00"
	assert_file_contains "$GITHUB_OUTPUT" "passed=true"
}

@test "aggregate-results: sums node metrics across matrix summaries" {
	_write_summary node-results node-version "20" 5 1 6 80.00 true
	_write_summary node-results node-version "22" 7 0 7 90.00 true

	run env RESULTS_DIR=node-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=12"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=13"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.00"
	assert_file_contains "$GITHUB_OUTPUT" "passed=true"
}

@test "aggregate-results: marks failed when any python matrix cell failed" {
	_write_summary python-results python-version "3.12" 5 0 5 80.00 true
	_write_summary python-results python-version "3.14" 3 2 5 70.00 false

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}

@test "aggregate-results: marks failed when any rust matrix cell failed" {
	_write_summary rust-results rust-toolchain "stable" 5 0 5 80.00 true
	_write_summary rust-results rust-toolchain "beta" 3 2 5 70.00 false

	run env RESULTS_DIR=rust-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}

@test "aggregate-results: marks failed when any node matrix cell failed" {
	_write_summary node-results node-version "20" 5 0 5 80.00 true
	_write_summary node-results node-version "22" 3 2 5 70.00 false

	run env RESULTS_DIR=node-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}

@test "aggregate-results: validates summary count against matrix json" {
	_write_summary python-results python-version "3.12" 5 0 5 80.00 true

	run env \
		RESULTS_DIR=python-results \
		MATRIX_JSON='{"include":[{"python-version":"3.12"},{"python-version":"3.14"}]}' \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "Expected 2 matrix summaries, found 1"
}

@test "aggregate-results: fails without GITHUB_OUTPUT" {
	_write_summary python-results python-version "3.12" 5 0 5 80.00 true

	run env -u GITHUB_OUTPUT RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}

@test "aggregate-results: fails when no summaries exist" {
	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "No matrix summaries found"
}

@test "aggregate-results: requires RESULTS_DIR" {
	run env -u RESULTS_DIR \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "RESULTS_DIR is required"
}
