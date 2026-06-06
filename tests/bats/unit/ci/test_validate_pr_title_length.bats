#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for validate-pr-title-length.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-pr-title-length.sh"

setup() {
	OUTPUT_FILE="${BATS_TEST_TMPDIR}/github_output"
	: >"$OUTPUT_FILE"
}

@test "validate-pr-title-length: passes when within limit" {
	run env \
		TITLE="feat: add widget" \
		MAX_LENGTH="72" \
		GITHUB_OUTPUT="$OUTPUT_FILE" \
		bash "$SCRIPT"

	assert_success
	run grep -F 'error=' "$OUTPUT_FILE"
	assert_success
}

@test "validate-pr-title-length: fails when title exceeds limit" {
	run env \
		TITLE="feat: $(printf 'x%.0s' {1..80})" \
		MAX_LENGTH="72" \
		GITHUB_OUTPUT="$OUTPUT_FILE" \
		bash "$SCRIPT"

	assert_failure
	run grep -F 'error=PR title exceeds maximum length of 72 characters' "$OUTPUT_FILE"
	assert_success
}

@test "validate-pr-title-length: skips check when max-length is zero" {
	run env \
		TITLE="feat: $(printf 'x%.0s' {1..80})" \
		MAX_LENGTH="0" \
		GITHUB_OUTPUT="$OUTPUT_FILE" \
		bash "$SCRIPT"

	assert_success
}

@test "validate-pr-title-length: skips invalid max-length values" {
	run env \
		TITLE="feat: add widget" \
		MAX_LENGTH="not-a-number" \
		GITHUB_OUTPUT="$OUTPUT_FILE" \
		bash "$SCRIPT"

	assert_success
}
