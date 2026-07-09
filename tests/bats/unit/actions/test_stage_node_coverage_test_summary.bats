#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for stage-node-coverage-test-summary.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || return 1
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/stage-node-coverage-test-summary.sh"
}

teardown() {
	teardown_temp_dir
}

@test "stage-node-coverage-test-summary: preserves working-directory prefix" {
	mkdir -p apps/web/coverage
	echo '{"total":{}}' >apps/web/coverage/coverage-summary.json

	WORKING_DIRECTORY=apps/web \
		COVERAGE_SUMMARY_FILE=coverage/coverage-summary.json \
		COVERAGE=true \
		run bash "$SCRIPT"
	assert_success
	assert_file_exists node-coverage-staged/apps/web/coverage/coverage-summary.json
}

@test "stage-node-coverage-test-summary: fails when coverage requested but summary missing" {
	WORKING_DIRECTORY=apps/web \
		COVERAGE_SUMMARY_FILE=coverage/coverage-summary.json \
		COVERAGE=true \
		run bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::"
	assert_output --partial "apps/web/coverage/coverage-summary.json"
	run test ! -e node-coverage-staged
	assert_success
}

@test "stage-node-coverage-test-summary: skips with notice when coverage not requested and summary missing" {
	WORKING_DIRECTORY=apps/web \
		COVERAGE_SUMMARY_FILE=coverage/coverage-summary.json \
		COVERAGE=false \
		run bash "$SCRIPT"
	assert_success
	assert_output --partial "::notice::"
	run test ! -e node-coverage-staged
	assert_success
}

@test "stage-node-coverage-test-summary: fails when coverage flag omitted" {
	run env -u COVERAGE \
		WORKING_DIRECTORY=apps/web \
		COVERAGE_SUMMARY_FILE=coverage/coverage-summary.json \
		bash "$SCRIPT"
	assert_failure
	assert_output --partial "COVERAGE is required"
	run test ! -e node-coverage-staged
	assert_success
}

@test "stage-node-coverage-test-summary: never zero-falls-back on missing summary" {
	WORKING_DIRECTORY=apps/web \
		COVERAGE_SUMMARY_FILE=coverage/coverage-summary.json \
		COVERAGE=false \
		run bash "$SCRIPT"
	assert_success
	refute_output --partial '"total"'
	run test ! -e node-coverage-staged
	assert_success
}
