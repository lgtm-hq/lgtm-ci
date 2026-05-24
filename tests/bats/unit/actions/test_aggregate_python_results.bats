#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/aggregate-python-results.sh

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
	local version="$1"
	local passed="$2"
	local failed="$3"
	local total="$4"
	local coverage="$5"
	local all_passed="$6"
	local dir="python-results/python-results-${version}"

	mkdir -p "$dir"
	cat >"${dir}/summary.json" <<EOF
{
  "coverage-percent": "${coverage}",
  "passed": "${all_passed}",
  "python-version": "${version}",
  "tests-failed": "${failed}",
  "tests-passed": "${passed}",
  "tests-total": "${total}"
}
EOF
}

@test "aggregate-python-results: sums metrics across matrix summaries" {
	_write_summary "3.12" 5 1 6 80.00 true
	_write_summary "3.14" 7 0 7 90.00 true

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-python-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=12"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=13"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.00"
	assert_file_contains "$GITHUB_OUTPUT" "passed=true"
}

@test "aggregate-python-results: marks failed when any matrix cell failed" {
	_write_summary "3.12" 5 0 5 80.00 true
	_write_summary "3.14" 3 2 5 70.00 false

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-python-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}

@test "aggregate-python-results: validates summary count against matrix json" {
	_write_summary "3.12" 5 0 5 80.00 true

	run env \
		RESULTS_DIR=python-results \
		MATRIX_JSON='{"include":[{"python-version":"3.12"},{"python-version":"3.14"}]}' \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-python-results.sh"

	assert_failure
	assert_output --partial "Expected 2 matrix summaries, found 1"
}

@test "aggregate-python-results: fails when no summaries exist" {
	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-python-results.sh"

	assert_failure
	assert_output --partial "No matrix summaries found"
}
