#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/testing/rust/parse-rust-test-results.sh"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

@test "parse-rust-test-results parses junit and excludes skipped from pass rate total" {
	install_fixture "rust/junit-skipped-pass-rate.xml" "${BATS_TEST_TMPDIR}/junit.xml"

	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=junit.xml \
		COVERAGE_ENABLED=false \
		bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=5"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=2"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=7"
	assert_file_contains "$GITHUB_OUTPUT" "tests-ran=true"
}

@test "parse-rust-test-results extracts coverage percent from lcov when enabled" {
	install_fixture "rust/junit-two-tests.xml" "${BATS_TEST_TMPDIR}/junit.xml"
	install_fixture "rust/coverage-full.lcov" "${BATS_TEST_TMPDIR}/rust-coverage.lcov"

	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=junit.xml \
		LCOV_FILE=rust-coverage.lcov \
		COVERAGE_ENABLED=true \
		bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=100.00"
}

@test "parse-rust-test-results calculates partial coverage correctly" {
	install_fixture "rust/junit-one-test.xml" "${BATS_TEST_TMPDIR}/junit.xml"
	install_fixture "rust/coverage-partial.lcov" "${BATS_TEST_TMPDIR}/rust-coverage.lcov"

	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=junit.xml \
		LCOV_FILE=rust-coverage.lcov \
		COVERAGE_ENABLED=true \
		bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=75.00"
}

@test "parse-rust-test-results fails when coverage enabled but lcov file is missing" {
	install_fixture "rust/junit-one-test.xml" "${BATS_TEST_TMPDIR}/junit.xml"

	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=junit.xml \
		LCOV_FILE=missing.lcov \
		COVERAGE_ENABLED=true \
		bash "$SCRIPT"
	assert_failure
}

@test "parse-rust-test-results fails when junit file is missing" {
	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=missing.xml \
		COVERAGE_ENABLED=false \
		bash "$SCRIPT"
	assert_failure
}

# #1080: the script runs under set -euo pipefail; a large report or a
# one-line report must still leave a valid results.v1 document behind.
@test "parse-rust-test-results writes a valid results.v1 document for a large one-line report" {
	local junit="${BATS_TEST_TMPDIR}/junit.xml"
	{
		printf '<?xml version="1.0"?><testsuites tests="1500" failures="0" errors="0" skipped="0" time="3.25"><testsuite name="s" tests="1500" failures="0" errors="0" skipped="0">'
		for i in $(seq 1 1500); do
			printf '<testcase name="crate::module::very_descriptive_test_name_number_%d" classname="crate::module" time="0.002"/>' "$i"
		done
		printf '</testsuite></testsuites>'
	} >"$junit"
	[[ "$(wc -c <"$junit")" -gt 65536 ]]
	run env JUNIT_FILE="$junit" COVERAGE_ENABLED=false RESULTS_OUTPUT="${BATS_TEST_TMPDIR}/results.json" \
		bash "${PROJECT_ROOT}/scripts/ci/testing/rust/parse-rust-test-results.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=1500"
	run jq -c '[.status, .counts.total, .duration_ms]' "${BATS_TEST_TMPDIR}/results.json"
	assert_output '["passed",1500,3250]'
}
