#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/set-conditional-output.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/set-conditional-output.sh"

setup() {
	setup_github_env
}

teardown() {
	teardown_github_env
}

@test "set-conditional-output.sh: writes true when condition matches default success" {
	run env OUTPUT_NAME=passed CONDITION_VALUE=success bash "$SCRIPT"
	assert_success
	run grep -q '^passed=true$' "$GITHUB_OUTPUT"
	assert_success
}

@test "set-conditional-output.sh: writes false when condition does not match" {
	run env OUTPUT_NAME=passed CONDITION_VALUE=failure bash "$SCRIPT"
	assert_success
	run grep -q '^passed=false$' "$GITHUB_OUTPUT"
	assert_success
}

@test "set-conditional-output.sh: supports custom match and values" {
	run env \
		OUTPUT_NAME=validated \
		CONDITION_VALUE=true \
		MATCH_VALUE=true \
		TRUE_VALUE=true \
		FALSE_VALUE=skipped \
		bash "$SCRIPT"
	assert_success
	run grep -q '^validated=true$' "$GITHUB_OUTPUT"
	assert_success
}

@test "set-conditional-output.sh: custom false value when unmatched" {
	run env \
		OUTPUT_NAME=validated \
		CONDITION_VALUE=false \
		MATCH_VALUE=true \
		TRUE_VALUE=true \
		FALSE_VALUE=skipped \
		bash "$SCRIPT"
	assert_success
	run grep -q '^validated=skipped$' "$GITHUB_OUTPUT"
	assert_success
}

@test "set-conditional-output.sh: fails without OUTPUT_NAME" {
	run env -u OUTPUT_NAME CONDITION_VALUE=success bash "$SCRIPT"
	assert_failure
	assert_output --partial "OUTPUT_NAME is required"
}
