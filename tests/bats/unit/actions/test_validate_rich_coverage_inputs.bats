#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/validate-rich-coverage-inputs.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-rich-coverage-inputs.sh"

@test "validate-rich-coverage-inputs.sh: fails when COVERAGE_FILE empty" {
	run env COVERAGE_FILE="" bash "$SCRIPT"
	assert_failure
	assert_output --partial "rich-coverage-comment requires coverage-file"
}

@test "validate-rich-coverage-inputs.sh: fails when COVERAGE_FILE unset" {
	run env -u COVERAGE_FILE bash "$SCRIPT"
	assert_failure
	assert_output --partial "rich-coverage-comment requires coverage-file"
}

@test "validate-rich-coverage-inputs.sh: succeeds when COVERAGE_FILE set" {
	run env COVERAGE_FILE="coverage/summary.json" bash "$SCRIPT"
	assert_success
}
