#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/fail-with-exit-code.sh

load "../../../helpers/common"

@test "fail-with-exit-code: exits successfully for zero" {
	run env EXIT_CODE=0 bash "${PROJECT_ROOT}/scripts/ci/actions/fail-with-exit-code.sh"

	assert_success
}

@test "fail-with-exit-code: passes through valid non-zero exit code" {
	run env EXIT_CODE=42 bash "${PROJECT_ROOT}/scripts/ci/actions/fail-with-exit-code.sh"

	assert_failure 42
	assert_output --partial "Command failed with exit code 42"
}

@test "fail-with-exit-code: rejects non-numeric exit code" {
	run env EXIT_CODE=abc bash "${PROJECT_ROOT}/scripts/ci/actions/fail-with-exit-code.sh"

	assert_failure
	assert_output --partial "Invalid exit code: abc"
}

@test "fail-with-exit-code: rejects exit codes above shell range" {
	run env EXIT_CODE=256 bash "${PROJECT_ROOT}/scripts/ci/actions/fail-with-exit-code.sh"

	assert_failure
	assert_output --partial "Exit code out of range: 256"
}
