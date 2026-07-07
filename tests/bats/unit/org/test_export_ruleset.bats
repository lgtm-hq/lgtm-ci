#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/org/export-ruleset.sh (mocked gh, no live API)

load "../../../helpers/common"
load "../../../helpers/mocks"

FIXTURE_RELATIVE="json/org_ruleset_example.json"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/org/export-ruleset.sh"
	export FIXTURE="${FIXTURES_DIR}/${FIXTURE_RELATIVE}"
}

teardown() {
	restore_path
	teardown_temp_dir
}

mock_gh_with_fixture() {
	mock_command_record "gh" "$(cat "$FIXTURE")"
}

@test "export-ruleset: prints ruleset JSON to stdout" {
	mock_gh_with_fixture
	run bash "$SCRIPT" checks-example 9999999
	assert_success
	assert_output --partial '"name": "checks-example"'
	assert_output --partial "tests / Example Tests"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output --partial "api orgs/lgtm-hq/rulesets/9999999"
}

@test "export-ruleset: -o writes JSON to a file" {
	mock_gh_with_fixture
	local out="${BATS_TEST_TMPDIR}/ruleset.json"
	run bash "$SCRIPT" checks-example 9999999 -o "$out"
	assert_success
	assert_output --partial "do not commit"
	run jq -r '.name' "$out"
	assert_output "checks-example"
}

@test "export-ruleset: fails when fetched name does not match" {
	mock_gh_with_fixture
	run bash "$SCRIPT" checks-mismatch 9999999
	assert_failure
	assert_output --partial "Ruleset name mismatch"
}

@test "export-ruleset: fails on non-numeric ruleset id" {
	run bash "$SCRIPT" checks-example not-a-number
	assert_failure
	assert_output --partial "must be numeric"
}

@test "export-ruleset: fails when gh api errors" {
	mock_command "gh" "" 1
	run bash "$SCRIPT" checks-example 9999999
	assert_failure
	assert_output --partial "Failed to fetch"
}

@test "export-ruleset: fails with usage when arguments are missing" {
	run bash "$SCRIPT" checks-example
	assert_failure
	assert_output --partial "Usage:"
}
