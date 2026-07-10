#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/health-lib.sh

load "../../../../helpers/common"

LIB="${PROJECT_ROOT}/scripts/ci/actions/docker/health-lib.sh"
ACTIONS_LIB="${PROJECT_ROOT}/scripts/ci/lib/actions.sh"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "health-lib.sh: parse_duration_seconds accepts Ns form" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "45s"
	'
	assert_success
	assert_output "45"
}

@test "health-lib.sh: parse_duration_seconds accepts bare seconds" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "12"
	'
	assert_success
	assert_output "12"
}

@test "health-lib.sh: parse_duration_seconds defaults to 30s" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds
	'
	assert_success
	assert_output "30"
}

@test "health-lib.sh: parse_duration_seconds rejects invalid input" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "30x"
	'
	assert_failure
	assert_output --partial "Invalid HEALTH_CHECK_TIMEOUT"
}

@test "health-lib.sh: can be sourced multiple times" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "5s"
	'
	assert_success
	assert_output "5"
}
