#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/aggregate-rust-results.sh

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
	local toolchain="$1"
	local passed="$2"
	local failed="$3"
	local total="$4"
	local coverage="$5"
	local all_passed="$6"
	local dir="rust-results/rust-results-${toolchain}"

	mkdir -p "$dir"
	cat >"${dir}/summary.json" <<EOF
{
  "coverage-percent": "${coverage}",
  "passed": "${all_passed}",
  "rust-toolchain": "${toolchain}",
  "tests-failed": "${failed}",
  "tests-passed": "${passed}",
  "tests-total": "${total}"
}
EOF
}

@test "aggregate-rust-results: sums metrics across matrix summaries" {
	_write_summary "stable" 5 1 6 80.00 true
	_write_summary "beta" 7 0 7 90.00 true

	run env RESULTS_DIR=rust-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-rust-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=12"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=13"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.00"
	assert_file_contains "$GITHUB_OUTPUT" "passed=true"
}

@test "aggregate-rust-results: marks failed when any matrix cell failed" {
	_write_summary "stable" 5 0 5 80.00 true
	_write_summary "beta" 3 2 5 70.00 false

	run env RESULTS_DIR=rust-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-rust-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}
