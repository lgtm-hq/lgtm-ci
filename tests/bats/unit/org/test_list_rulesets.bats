#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/org/list-rulesets.sh (mocked gh, no live API)

load "../../../helpers/common"
load "../../../helpers/mocks"

FIXTURE_RELATIVE="json/org_rulesets_list.json"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/org/list-rulesets.sh"
	export FIXTURE="${FIXTURES_DIR}/${FIXTURE_RELATIVE}"
}

teardown() {
	restore_path
	teardown_temp_dir
}

mock_gh_with_fixture() {
	mock_command_record "gh" "$(cat "$FIXTURE")"
}

@test "list-rulesets: prints table with id, name, enforcement, and repos" {
	mock_gh_with_fixture
	run bash "$SCRIPT" -q
	assert_success
	assert_output --partial "16132640"
	assert_output --partial "checks-py-lintro"
	assert_output --partial "active"
	assert_output --partial "py-lintro"
	assert_output --partial "16132643"
	assert_output --partial "checks-rustume"
	assert_output --partial "evaluate"
	assert_output --partial "Rustume"
}

@test "list-rulesets: table has header row" {
	mock_gh_with_fixture
	run bash "$SCRIPT" -q
	assert_success
	assert_output --partial "ID"
	assert_output --partial "NAME"
	assert_output --partial "ENFORCEMENT"
	assert_output --partial "REPOS"
}

@test "list-rulesets: calls gh api with correct endpoint" {
	mock_gh_with_fixture
	run bash "$SCRIPT" -q
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output --partial "api --paginate orgs/lgtm-hq/rulesets?per_page=100"
}

@test "list-rulesets: LGTM_ORG overrides the organization" {
	mock_gh_with_fixture
	LGTM_ORG="other-org" run bash "$SCRIPT" -q
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output --partial "api --paginate orgs/other-org/rulesets?per_page=100"
}

@test "list-rulesets: logs info when not quiet" {
	mock_gh_with_fixture
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Fetching rulesets"
	assert_output --partial "2 ruleset(s) found"
}

@test "list-rulesets: -q suppresses info log lines" {
	mock_gh_with_fixture
	run bash "$SCRIPT" -q
	assert_success
	refute_output --partial "Fetching rulesets"
	refute_output --partial "ruleset(s) found"
}

@test "list-rulesets: handles empty ruleset array" {
	mock_command_record "gh" "[]"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No rulesets found"
}

@test "list-rulesets: fails when gh api errors" {
	mock_command "gh" "" 1
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Failed to fetch"
}

@test "list-rulesets: fails on unexpected non-array response" {
	mock_command "gh" '{"error":"bad"}'
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "expected a JSON array"
}

@test "list-rulesets: fails on unknown argument" {
	run bash "$SCRIPT" --bogus
	assert_failure
	assert_output --partial "Unknown argument"
}
