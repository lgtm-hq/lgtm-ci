#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/assert-required-check.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/assert-required-check.sh"

@test "assert-required-check: passes when upstream succeeded" {
	run env UPSTREAM_RESULT=success bash "${SCRIPT}"

	assert_success
	assert_output --partial "Required check satisfied"
}

@test "assert-required-check: passes with passed and status outputs" {
	run env \
		UPSTREAM_RESULT=success \
		PASSED_OUTPUT=true \
		STATUS_OUTPUT=passed \
		bash "${SCRIPT}"

	assert_success
}

@test "assert-required-check: fails when upstream did not succeed" {
	run env UPSTREAM_RESULT=failure bash "${SCRIPT}"

	assert_failure
	assert_output --partial "Upstream job failed"
}

@test "assert-required-check: fails when passed output is not true" {
	run env \
		UPSTREAM_RESULT=success \
		PASSED_OUTPUT=false \
		bash "${SCRIPT}"

	assert_failure
	assert_output --partial "passed output is not true"
}

@test "assert-required-check: fails when status output mismatches expected" {
	run env \
		UPSTREAM_RESULT=success \
		STATUS_OUTPUT=failed \
		STATUS_EXPECTED=passed \
		bash "${SCRIPT}"

	assert_failure
	assert_output --partial "status is not passed"
}

@test "assert-required-check: writes github outputs on success" {
	local output_file="${BATS_TEST_TMPDIR}/github_output"
	run env \
		UPSTREAM_RESULT=success \
		GITHUB_OUTPUT="${output_file}" \
		bash "${SCRIPT}"

	assert_success
	[[ -f "${output_file}" ]] || fail "expected GITHUB_OUTPUT file"
	run grep -F 'exit-code=0' "${output_file}"
	assert_success
	run grep -F 'status=passed' "${output_file}"
	assert_success
}

@test "assert-required-check: rejects unset upstream result" {
	run env -u UPSTREAM_RESULT bash "${SCRIPT}"

	assert_failure
	assert_output --partial "UPSTREAM_RESULT not set"
}
