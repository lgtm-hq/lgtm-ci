#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/derive-artifact-key.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/derive-artifact-key.sh"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

key_for() {
	: >"$GITHUB_OUTPUT"
	run env TAG_PREFIX="$1" bash "$SCRIPT"
	assert_success
	get_github_output "key"
}

@test "derive-artifact-key: fails without GITHUB_OUTPUT" {
	run env -u GITHUB_OUTPUT TAG_PREFIX=v bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}

@test "derive-artifact-key: plain prefix stays readable with a digest suffix" {
	local key
	key="$(key_for v)"
	[[ "$key" =~ ^v-[0-9a-f]{8}$ ]]
}

@test "derive-artifact-key: characters artifact names reject are replaced" {
	local key
	key="$(key_for 'cli/v')"
	[[ "$key" =~ ^cli_v-[0-9a-f]{8}$ ]]
	key="$(key_for 'a:b"c<d>e|f*g?h')"
	[[ "$key" =~ ^a_b_c_d_e_f_g_h-[0-9a-f]{8}$ ]]
}

@test "derive-artifact-key: sanitized collisions stay distinct" {
	[[ "$(key_for 'cli/v')" != "$(key_for 'cli_v')" ]]
}

@test "derive-artifact-key: empty prefix yields a digest only" {
	local key
	key="$(key_for '')"
	[[ "$key" =~ ^[0-9a-f]{8}$ ]]
}

@test "derive-artifact-key: long prefixes are truncated but still keyed" {
	local key
	key="$(key_for "$(printf 'x%.0s' {1..60})")"
	[[ "${#key}" -eq 41 ]]
}
